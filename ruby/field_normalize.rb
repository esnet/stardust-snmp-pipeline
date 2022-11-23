require '/usr/lib/stardust/pipeline/ruby/lib/ratecache.rb'

##
# Utility script for normaalizing a set of values fields into a single field
# based on a precedence.

def register(params)
    #The source field where we will pull values
    @source = params["source"]
    #The dest field where we will merge - MUST BE IN SQUARE BRACKET FORMAT e.g [FIELDNAME] 
    @target = params["target"]
 end

def filter(event)
    #Make sure we have required params
    if !@source then
        logger.error("Missing source in field_normalize. Skipping.")
        return [event]
    end
    if !@target then
        logger.error("Missing target in field_normalize. Skipping.")
        return [event]
    end
    bucket_id = event.get("bucket_id")
    if !bucket_id then
        logger.error("Missing bucket_id in event. Skipping.")
        return [event]
    end
    #cache key is bucket id and target
    cache_key = "#{bucket_id}#{@target}"

    #Check to see if we already normalized field so we don't write twice
    if RateCache.get(cache_key) then
        return [ event ]
    end

    #Go through source fields and set target to first non-null value
    Array(@source).each do |src|
        normalized_val = event.get(src)
        if normalized_val then #Ruby matces everything but nil/false
            event.set("#{@target}", normalized_val)
            #mark as written in cache
            RateCache.put(cache_key, true)
            break
        end
    end

    return [event]
end

