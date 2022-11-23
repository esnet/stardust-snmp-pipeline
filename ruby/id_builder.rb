require '/usr/lib/stardust/pipeline/ruby/lib/redispool.rb'

def register(params)
    #Require one of these - preference given to values if given
    @config = params["config"]
 end

def _filter(event, redis)
    #Check if config
    config = event.get(@config)
    if !config || !config.kind_of?(Hash) then
        logger.error("No value_id config provided, so canceling")
        event.cancel()
    end

    #Indicate whether we need to aggregate - default is false
    if config["aggregate"] then
        event.set("[@do_aggregation]", true)
    else
        event.set("[@do_aggregation]", false)
    end

    #Check for target field - default is [meta][id]
    target = "[meta][id]"
    if config["target"] then
        target = config["target"]
    end
    #check for key functions
    key_funcs = config["key"]
    if !key_funcs || !key_funcs.kind_of?(Array) then
        logger.error("value_id provided that is missing 'key', canceling")
        event.cancel()
    end

    #build the id
    value_id = key_function_multi("", event, key_funcs, redis)
    if value_id && !value_id.empty? then
        event.set(target, value_id)
    else
        logger.debug("Unable to generate a valid id for event, canceling. This is common when metadata is still bootstrapping.")
        event.cancel()
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
        logger.error("Caught ruby exception in id_builder.rb #{exception.message}")
        event.cancel()
    end
    
    return [event]
end