require '/usr/lib/stardust/pipeline/ruby/lib/meta.rb'
require '/usr/lib/stardust/pipeline/ruby/lib/values.rb'
require '/usr/lib/stardust/pipeline/ruby/lib/redispool.rb'

def register(params)
    #Require one of these - preference given to values if given
    @config = params["config"]
    #Optional
    @interval_field = params["interval_field"] ? params["interval_field"] : "interval"
    ##number of intervals before expiring rate keys in redis
    @expire_intervals = params["expire_intervals"] ? params["expire_intervals"] : 5
 end

def _filter(event, redis)
    #calculate current time bin
    interval = event.get(@interval_field).to_i
    #calculate expires for redis keys
    expire_seconds = interval * @expire_intervals
    
    #Check if values - if you only care about time bin calculation then this is ok
    config = event.get(@config)
    if !config || !config.kind_of?(Array) then
        logger.debug("No relation map config provided, so skipping")
        return [event]
    end
    #Iterate through config 
    Array(config).each do |relation_map|
        #check for name
        if !relation_map["name"] || relation_map["name"].empty? then
            logger.error("relation_map provided that is missing 'name'")
            next
        end

        #check for key functions
        key_funcs = relation_map["key"]
        if !key_funcs || !key_funcs.kind_of?(Array) then
            logger.error("relation_map provided that is missing 'key'")
            next
        end

        #get and format value from field
        field = relation_map["field"]
        if !field then
            logger.error("relation_map provided that is missing field source")
            next
        end
        if !field["source"] then
            logger.error("relation_map provided that is missing field source")
            next
        end
        if !field["type"] then
            #default to string type
            field["type"] = "str"
        end
        #if field exists then set target
        v = event.get(field["source"])
        if v then
            #first do type conversion in case any additional formatting options
            v, is_num = to_type(v, field["type"], field)
        else
            next
        end
        #if didn't get v then next
        if v.nil? then
            next
        end

        #calculate key
        k = key_function_multi(relation_map["name"], event, key_funcs, redis)
        if !k || k.empty? then
            next
        end
    
        #write to redis
        relation_redis_set(k, v, expire_seconds, redis)
    end

    return [event]
end


##
# Handles exception in call to main _filter function.
# May want to get rid of this if causes performance issues,
# but provides catch-all so eexception does not kill logstash
# and provides more helpful output when exceptions do occur.
def filter(event)
    #catch exception
    begin
        redis = RedisPool.get()
        result = _filter(event, redis)
        RedisPool.finalize(redis)
        return result
    rescue => exception
        RedisPool.finalize(redis)
        logger.error("Caught ruby exception in relation_builder.rb #{exception.message}")
        event.cancel()
    end

    return [event]
end