#!/usr/bin/lua
--[[
    Karl Palsson, 2019 <karlp@remake.is>
]]

local json = require("cjson.safe")
-- cjson specific
json.encode_sparse_array(true)
local uloop = require("uloop")
uloop.init()
local mosq = require("mosquitto")
mosq.init()
local PU = require("posix.unistd")
local Pt = require("posix.time")
local uci = require("uci")
local ugly = require("remake.uglylog")

local pl = require("pl.import_into")()
local args = pl.lapp [[
    -H,--mqtt_host (default "localhost") MQTT host to listen to
    -v,--verbose (0..7 default 4) Logging level, higher == more
    -i,--instance (string) UCI service instance to run

    "All" configuration is loaded from the UCI file for the given instance

statsd options
    -S,--statsd_host (default "localhost") StatsD server address
    --statsd_port (default 8125) StatsD port
    --statsd_namespace (default "apps.output-db") (instance id will be appended)
]]

local statsd = require("statsd")({
    namespace = args.statsd_namespace .. "." .. args.instance,
    host = args.statsd_host,
    port = args.statsd_port,
})
-- Default global configuration
local cfg = {
    APP_NAME = "output-db",
    MOSQ_CLIENT_ID = string.format("output-db-%s-%d", args.instance, PU.getpid()),
    MOSQ_IDLE_LOOP_MS = 500,
    DEFAULT_STORE_TYPES = {"cumulative_wh"},
    -- We're going to listen to more than we theoretically need to, but we can just drop it
    DEFAULT_TOPIC_DATA = "status/+/json/interval/%dmin/#",
    DEFAULT_TOPIC_METADATA = "status/+/json/cabinet/#",
    DEFAULT_INTERVAL = 15, -- in minutes
    DATABASE_VERSION = 1,
    PATH_DEFAULT = "/usr/share/output-db",
    PATH_USER = "/etc/output-db",
}
ugly.initialize(cfg.APP_NAME, args.verbose or 4)

-- Read instance configuration and merge
local x = uci.cursor()
x:foreach(cfg.APP_NAME, "instance", function(s)
    if s[".name"] ~= args.instance then return end
    cfg.uci = s
end)

x:foreach("system", "system", function(s)
    if s.rme_stablemac then
        cfg.gateid = s.rme_stablemac
        return
    end
end)


-- checks and fills in defaults
-- raises if required fields are not available
local function cfg_validate(c)
    c.interval = c.uci.interval or cfg.DEFAULT_INTERVAL
    c.topic_data_in = string.format(cfg.DEFAULT_TOPIC_DATA, c.interval)
    c.topic_metadata_in = cfg.DEFAULT_TOPIC_METADATA
    c.store_types = c.uci.store_types or cfg.DEFAULT_STORE_TYPES

    local function read_template(instance, type)
        local err, custom, default
        custom, err = pl.file.read(string.format("%s/custom.%s.%s.query", cfg.PATH_USER, instance, type))
        default, err = pl.file.read(string.format("%s/default.%s.query", cfg.PATH_DEFAULT, type))
        if not custom and not default then
            ugly.fatal("No custom query and unable to read default either: %s", err)
            os.exit()
        end
        return custom or default
    end

    c.template_data = read_template(args.instance, "data")
    c.template_metadata = read_template(args.instance, "metadata")
    return c
end

cfg = cfg_validate(cfg)
ugly.debug("Starting operations with config: %s", pl.pretty.write(cfg))

local function timestamp_ms()
    local tspec = Pt.clock_gettime(Pt.CLOCK_REALTIME)
    return tspec.tv_sec * 1000 + math.floor(tspec.tv_nsec / 1e6)
end

-- Live variables, just kept in a table for sanity of access
local state = {

}

local function db_connect()
    local dname = string.format("luasql.%s", cfg.uci.driver)
    local driver = require (dname)
    if not driver then error("Couldn't load driver for: " .. dname) end
    local env = driver[cfg.uci.driver]()
    if not env then error("Couldn't open environment for driver") end
    local params = {cfg.uci.dbname, cfg.uci.dbuser, cfg.uci.dbpass, cfg.uci.dbhost}
    if cfg.uci.dbport then table.insert(params, cfg.uci.dbport) end
    local conn, err = env:connect(table.unpack(params))
    if not conn then
        error(string.format("Couldn't connect with %s: %s", pl.pretty.write(params), err))
    end
    return conn
end

local conn = db_connect()

local function db_validate_schema(conn, driver)
    -- Load the schema for this driver
    -- This is convoluted, because mysql doesn't let you run multiple statements in one go.
    local schemas, ferr = pl.dir.getfiles(cfg.PATH_DEFAULT, string.format("schema.%s.*.sql", driver))
    if not schemas then error(string.format("Couldn't load schema(s) for driver: %s: %s", driver, ferr)) end

    -- Creates tables if they don't exist.
    for _,fn in ipairs(schemas) do
        local schema, serr = pl.file.read(fn)
        if not schema then error(string.format("Failed to read schema file: %s: %s", fn, serr)) end
        local rows, err = conn:execute(schema)
        if not rows then
            error("Failed to update schema: " .. err)
        else
            print("update schema returned", rows)
        end
    end

    local q = [[select val from metadata where mkey = 'version']]
    local cur = conn:execute(q)
    if not cur then error("Couldn't execute the version check") end
    local row = cur:fetch({}, "a")
    local version
    while row do
        version = tonumber(row.val)
        row = cur:fetch (row, "a")
    end

    if version then
        if version < cfg.DATABASE_VERSION then
            -- TODO Here should be a function to deal with the old database.
            error("No Function to deal with different database version")
        end
        ugly.debug("Database running version: %d", version)
    else
        local rows, err = conn:execute(string.format([[insert into metadata (mkey, val) values ('version', '%d')]], cfg.DATABASE_VERSION))
        if not rows then
            print("setting version failed: ", err)
            error("failed to set version")
        end
    end
end

if cfg.uci.validate_schema then
    db_validate_schema(conn, cfg.uci.driver)
else
    ugly.notice("Assuming database is compatible with validation. If you get errors, check your queries or schemas!");
end

local mqtt = mosq.new(cfg.MOSQ_CLIENT_ID, true)

if not mqtt:connect(args.mqtt_host, 1883, 60) then
    ugly.err("Aborting, unable to make MQTT connection")
    os.exit(1)
end

for _,topic in ipairs({cfg.topic_data_in, cfg.topic_metadata_in}) do
    local mid, code, err = mqtt:subscribe(topic, 0)
    if not mid then
        ugly.err("Aborting, unable to subscribe to: %s: %d %s", topic, code, err)
        os.exit(1)
    end
end

-- Make a unique key for a datapoint
-- This makes a key that is == the trailer of the mqtt topic,
local function make_key(device, datatype, channel)
    if channel then
        return string.format("%s/%s/%s", device, datatype, channel)
    else
        return string.format("%s/%s", device, datatype)
    end
end

-- return a properly formatted "safe" sql to execute based on a metadata branch/point
-- We write a row of metadata for every single point.  This makes some duplicates,
-- but makes it much easier to match things up in a database later.
-- NOTE: switching to luadbi and parameterized queries will dramatically change how the templates would work!
local function make_query_metadata(cabinet, deviceid, branch, point)
    -- make a timestamp for "last change"
    local ts_str = os.date("%FT%T")
    -- create a context object for them to use
    local context = {
        deviceid = deviceid,
        cabinet = cabinet,
        breakersize = branch.ampsize,
        label = branch.label,
        point = point.reading + 1, -- the interval data uses logical channel numbers, not zero based.
        phase = point.phase,
        gateid = cfg.gateid,
        ts = ts_str,
    }

    local t = pl.text.Template(cfg.template_metadata)
    return t:substitute(context)
end


-- return a properly formatted "safe" sql to execute based on the data payload
-- NOTE: switching to luadbi and parameterized queries will dramatically change how the templates would work!
local function make_query_data(key, payload)
    -- Convert our timestamp into an iso8601 datestring, so that it parses natively into different database backends
    -- (we don't care about milliseconds on minute level interval reporting)
    local ts_end = math.floor(payload.ts_end / 1000)
    local ts_str = os.date("%FT%T", ts_end)
    local value
    if key:find("cumulative_wh") then
        value = payload.max
    else
        value = payload.mean
    end
    -- Enrich the payload a bit before we give it to the template.
    payload.pname = key
    payload.selected = value
    payload.ts_ends = ts_str
    payload.period = cfg.interval * 60
    payload.gateid = cfg.gateid

    local t = pl.text.Template(cfg.template_data)
    return t:substitute(payload)
end

local function handle_interval_data(topic, jpayload)
    local segs = pl.stringx.split(topic, "/")
    local dtype = segs[7] -- yes. always!
    if not dtype then return end
    -- NB: _RIGHT_ HERE we make power bars look like anyone else. no special casing elsewhere!
    if dtype == "wh_in" then dtype = "cumulative_wh" end
    if not pl.tablex.find(cfg.store_types, dtype) then
        ugly.debug("Ignoring uninteresting data of type: %s", dtype)
        return
    end
    local device = segs[6]
    local channel = segs[8] -- may be nil
    local key = make_key(device, dtype, channel)

    -- find or insert key into sources table. -- or just _not_....
    -- let them have what they like here?

    local payload, err = json.decode(jpayload)
    if payload then
        statsd:increment("msgs.data")
        local ok, serr = conn:execute(make_query_data(key, payload))
        if ok then
            ugly.debug("Successfully exported data for key: %s", key)
            statsd:increment("db.insert-good")
        else
            -- FIXME - attempt to store a short queue here?  retry at all? or jsut log and continue?
            ugly.err("Failed to store data! %s", serr)
            statsd:increment("db.insert-fail")
        end
    else
        statsd:increment("msgs.invalid-data")
        ugly.err("Non JSON payload on topic: %s: %s ", topic, err)
    end
end

local function handle_metadata(topic, jpayload)
    local function handle_clean_json(p)
        if not p.type or p.type ~= "profile" then
            return nil, "unknown message type? " .. tostring(p.type)
        end
        if not p.version then
            return nil, "profile version not provided"
        end
        local n = 0
        if p.version == 0.3 then
            local cabinet = p.cabinet
            local deviceid = p.deviceid
            for _,branch in ipairs(p.branches) do
                for _,point in ipairs(branch.points) do
                    local ok, serr
                    local mkey = string.format("%s:%d", deviceid, point.reading + 1)
                    -- FIXME - this hardcodes the table name! that makes a complete mockery of our templates!
                    -- All this dance is to do an "upsert"
                    ok, serr = conn:execute(string.format([[select deviceid from sources where deviceid = '%s' and pointid = %d]], deviceid, point.reading + 1))
                    if ok then
                        if ok:numrows() == 0 then
                            ok, serr = conn:execute(string.format([[insert into sources (deviceid, pointid) values ('%s', %d)]], deviceid, point.reading + 1))
                            if ok then
                                ugly.debug("Inserted new source for metadata <%s>", mkey)
                            else
                                error("Unhandled error attempting to insert new metadata: " .. mkey)
                            end
                        else
                            ugly.debug("Metadata source already existed in db for <%s>", mkey)
                        end
                    else
                        error("Unhandled error attempting to check for device metadata: " .. mkey)
                    end
                    ok, serr = conn:execute(make_query_metadata(cabinet, deviceid, branch, point))
                    if ok then
                        if ok == 0 then
                            error("Metadata row wasn't found at update time for <%s:%d>", mkey)
                        end
                        statsd:increment("db.insert-good-meta")
                        n = n + 1
                    else
                        -- FIXME - attempt to store a short queue here?  retry at all? or jsut log and continue?
                        ugly.err("Failed to store metadata! %s", serr)
                        statsd:increment("db.insert-fail-meta")
                    end
                end
            end
        else
            return nil, "unhandled profile version: " .. tostring(p.version)
        end
        return n
    end

    local payload, err = json.decode(jpayload)
    if payload then
        statsd:increment("msgs.metadata")
        local records, err = handle_clean_json(payload)
        if records then
            ugly.info("Processed %s into %d database records", topic, records)
        else
            ugly.warning("Problems with json message on %s: %s", topic, err)
            statsd:increment("msgs.invalid-metadata")
        end
    else
        statsd:increment("msgs.invalid-metadata")
        ugly.err("Non JSON payload on topic: %s: %s ", topic, err)
    end
end

ugly.notice("Application startup complete")

mqtt.ON_MESSAGE = function(mid, topic, jpayload, qos, retain)
    if mosq.topic_matches_sub(cfg.topic_data_in, topic) then
        if retain then
            ugly.debug("Skipping retained messages on topic: %s, we might have already processed that", topic)
            return
        end
        return handle_interval_data(topic, jpayload)
    end
    if mosq.topic_matches_sub(cfg.topic_metadata_in, topic) then
        return handle_metadata(topic, jpayload)
    end
end

-- TODO - CAREFUL! you may want to have an onconnect handler that creates the db connection internally.
-- you may want to do this so you can have the threaded interface, but make sure that you do everything on the correct thread.?

local mqtt_read = uloop.fd_add(mqtt:socket(), function(ufd, events)
    mqtt:loop_read()
end, uloop.ULOOP_READ)

local mqtt_write = uloop.fd_add(mqtt:socket(), function(ufd, events)
    mqtt:loop_write()
end, uloop.ULOOP_WRITE)

local mqtt_idle_timer
mqtt_idle_timer = uloop.timer(function()
    -- just handle the mosquitto idle/misc loop
    local success, errno, err = mqtt:loop_misc()
    if not success then
        local errs = string.format("Lost MQTT connection: %s", err)
        ugly.crit(errs)
        -- FIXME - need to reconnect here!  (truly, monit restarting us is fast enough for 15minute data, but still....)
        error(errs)
    end
    mqtt_idle_timer:set(cfg.MOSQ_IDLE_LOOP_MS)
end, cfg.MOSQ_IDLE_LOOP_MS)

uloop.run()
