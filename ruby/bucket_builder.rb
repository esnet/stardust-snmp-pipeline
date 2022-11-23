require '/usr/lib/stardust/pipeline/ruby/lib/values.rb'

def register(params)
    #Require one of these - preference given to values if given
    @values = params["values"]
    @values_field = params["values_field"]
    #Optional
    ##Source should in theory work with numeric unix timestamps and Datetime fields
    @source_time_field = params["source_time_field"] ? params["source_time_field"] : "@timestamp"
    @target_time_field = params["target_time_field"] ? params["target_time_field"] : "start"
    @interval_field = params["interval_field"] ? params["interval_field"] : "interval"
    @bucket_prefix_field = params["bucket_prefix"] ? params["bucket_prefix"] : "[@metadata][metadata_lookup_keys][_root]"
 end

def _filter(event)
    #calculate current time bin
    raw_time = event.get(@source_time_field).to_i
    interval = event.get(@interval_field).to_i
    bucket_time = calculate_bin_time(raw_time, interval)
    if bucket_time.nil? then
        return [event]
    end
    event.set(@target_time_field, Time.at(bucket_time))

    #Check if values - if you only care about time bin calculation then this is ok
    values = @values
    if !values && @values_field && event.get(@values_field) then
        #if no values, then try values field
        values = event.get(@values_field)
    else
        logger.debug("No values or values_field, so skipping")
        return [event]
    end

    #Iterate through configs 
    Array(values).each do |v_spec|
        parse_vspec(v_spec, event, raw_time, interval, bucket_time, @bucket_prefix_field)
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
        result = _filter(event)
        return result
    rescue => exception
        logger.error("Caught ruby exception in bucket_builder.rb #{exception.message}")
        event.cancel()  
    end

    return [event]
end