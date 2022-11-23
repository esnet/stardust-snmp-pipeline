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
 
def _handle_meta_map(meta_map, event, key_funcs, expire_seconds, redis)
    #do different operations depending on whether target is set or hash
    if meta_map["type"] == "set" then
        #Validation
        if !meta_map["field"] then
            logger.error("meta_map provided that is missing field")
            return
        end
        if !meta_map["field"]["source"] then
            logger.error("meta_map provided that is missing field source")
            return
        end

        #Check if source field exists
        src = event.get(meta_map["field"]["source"])
        if !src then
            return
        end

        #Get key
        key = key_function_multi(meta_map["name"], event, key_funcs, redis)

        #write to redis
        meta_redis_write_set(key, src.to_s, expire_seconds, redis)
    else
        #Go through fields to see if we have any metadata
        if !meta_map["fields"] || !meta_map["fields"].kind_of?(Array) then
            logger.error("meta_map provided that is missing fields")
            return
        end
        metadata = {}
        Array(meta_map["fields"]).each do |field|
            #Error checking
            if !field["source"] then
                logger.error("meta_map provided that is missing field source")
                return
            end
            if !field["target"] then
                logger.error("meta_map provided that is missing field target")
                return
            end
            if !field["type"] then
                #default to string type
                field["type"] = "str"
            end
            #if field exists then set target
            src = event.get(field["source"])
            if src then
                #first do type conversion in case any additional formatting options
                src, is_num = to_type(src, field["type"], field)
                #Don't store empty strings
                if src != "" then
                    #then create a key indicating the type so can convert back when we read from redis
                    md_key = "#{field["type"]}__#{field["target"]}"
                    #then store using key and convert value to string for redis
                    metadata[md_key] = src.to_s
                end
            end
        end
        #If no metadata in the event, then we can quit
        if metadata.empty? then
            return
        end
        key = key_function_multi(meta_map["name"], event, key_funcs, redis)
        #write hash to redis
        meta_redis_write_hash(key, metadata, expire_seconds, redis)
    end
end

def _foreach(depth, field_names, meta_map, event, key_funcs, expire_seconds, redis)
    field = event.get(field_names[depth])
    if !field then
        return
    end
    #Make sure its a list - error if not
    if !field.kind_of?(Array)
        logger.error("meta_map provided with foreach field that is not an array")
        return
    end
    #Iterate through items in list we grabbed
    Array(field).each do |f|
        event.set("[@_iterator#{depth}]", f)
        next_depth = depth + 1
        if next_depth == field_names.length() then
            #no more fields - process event
            _handle_meta_map(meta_map, event, key_funcs, expire_seconds, redis)
        else
            # go the next level down
            _foreach(next_depth, field_names, meta_map, event, key_funcs, expire_seconds, redis)
        end
    end
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
    Array(config).each do |meta_map|
        #Make sure we have the name of the table where we will store this
        if !meta_map["name"] then
            logger.error("meta_map provided that is missing name")
            next
        end
        #check for key functions
        key_funcs = meta_map["key"]
        if !key_funcs || !key_funcs.kind_of?(Array) then
            logger.error("meta_map provided that is missing 'key'")
            next
        end
        
        #Check if we are pulling metadata from a list element or from base message
        if meta_map["foreach"] then
            if !meta_map["foreach"].kind_of?(Array)
                logger.error("meta_map provided with foreach that is not an array")
                next
            end
            event_copy = event.clone()
            #recursuvely process nested lists
            _foreach(0, meta_map["foreach"], meta_map, event_copy, key_funcs, expire_seconds, redis)
        else
            _handle_meta_map(meta_map, event, key_funcs, expire_seconds, redis)
        end
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
        logger.error("Caught ruby exception in meta_builder.rb #{exception.message}")
        event.cancel()
    end
    
    
    return [event]
end