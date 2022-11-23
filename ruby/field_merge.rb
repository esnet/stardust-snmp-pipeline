##
# Utility script for merging two object fields

def register(params)
    #The source field where we will pull values
    @source = params["source"]
    #The dest field where we will merge - MUST BE IN SQUARE BRACKET FORMAT e.g [FIELDNAME] 
    @target = params["target"]
 end

def filter(event)
    #Make sure we have required params
    if !@source then
        logger.error("Missing source in field_merge. Skipping.")
        return [event]
    end
    if !@target then
        logger.error("Missing target in field_merge. Skipping.")
        return [event]
    end

    #Get source
    src = event.get(@source)
    if !src || !src.kind_of?(Hash) then
        #don't complain, just exit
        return [event]
    end

    #NOTE: could check @target to make sure it has square brackets
    # but skipping for efficiency. 

    #walk through source
    Array(src).each do |k, v|
        event.set("#{@target}[#{k}]", v)
    end

    return [event]
end

