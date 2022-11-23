require '/usr/lib/stardust/pipeline/ruby/lib/meta.rb'
require '/usr/lib/stardust/pipeline/ruby/lib/values.rb'
require '/usr/lib/stardust/pipeline/ruby/lib/redispool.rb'

def register(params)
    #Require one of these - preference given to values if given
    @config = params["config"]
 end

def _filter(event, redis)
    #Check if config
    config = event.get(@config)
    if !config || !config.kind_of?(Array) then
        logger.debug("No meta_lookup config provided, so skipping")
        return [event]
    end

    #Iterate through config 
    Array(config).each do |meta_lookup|
        #Check type
        if !meta_lookup["type"] then
            logger.error("Must provide a meta_lookup type")
            next
        end
        #Check params
        if !meta_lookup["params"] then
            logger.error("Must provide meta_lookup params")
            next
        end
        #Check target
        if !meta_lookup["target"] then
            logger.error("Must provide meta_lookup target")
            next
        end

        #Lookup based on cache
        type = meta_lookup["type"].downcase
        result = nil
        if type == "cache" then
            result = mlookup_cache(event, meta_lookup["params"], redis)
        else
            logger.error("Unrecognized meta_lookup type #{type}")
            next
        end

        #merge into target - drop open and close [] so will be consistent if not included
        if result then
            target = meta_lookup["target"].sub(/^\[/, "").sub(/\]$/, "")
            Array(result).each do |k, v|
                #Type conversion - key in format type__key
                target_k = k
                k_parts = k.split("__")
                if k_parts.length() == 2 then
                    #convert value back to type
                    v, is_num = to_type(v, k_parts[0])
                    target_k = k_parts[1]
                end
                #add to metadata
                event.set("[#{target}][#{target_k}]", v)
            end
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
        logger.error("Caught ruby exception in meta_lookup.rb #{exception.message}")
        event.cancel()
    end

    return [event]
end