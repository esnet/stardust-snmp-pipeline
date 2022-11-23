require '/usr/lib/stardust/pipeline/ruby/lib/ratecache.rb'
require '/usr/lib/stardust/pipeline/ruby/lib/tmnxportid.rb'

#
#NOTE: Function names must be unique to all files in the logstash pipeline
# even if this is the only file imported. Logstash seems to share imports across all filters.
#

##
# Takes a logstash-like field spec and grabs value from json
def get_json_field(v, path_spec)
    if v.nil? || path_spec.nil? then
        logger.debug("get_json_field v and path_spec must not be nil")
        return
    end
    new_v = v
    path = path_spec.sub(/^\[/, "").sub(/\]$/, "").split("][")
    path.each do |p|
        if new_v.key?(p) then
            new_v = new_v[p]
        else
            return
        end
    end

    return new_v
end

def calculate_bin_time(raw_time, interval)
    #Make sure interval is greater than 0
    if interval.nil? || interval.to_i <= 0 then
        logger.error("Time interval must be greater than 0 to create bin")
        return
    end

    #Make sure we have a ts - technically 0 is a valid timestamp but assume conversion failed
    if !raw_time then
        logger.error("Did not calculate time bin because given time is nil or invalid")
        return
    end

    return (raw_time.to_i / interval.to_i) * interval.to_i
end

def to_boolean(value)
    case value
        when true, 'true', 1, '1', 't' then true
        else false
    end
end

##
# format a string in format ADDR_TYPE.NUM_OCTETS.DOTTED_IP
# IPv4 Example: 1.4.198.128.59.2 (1 means Ipv4, 4 octets, IP 198.128.59.2)
# IPv6 Example: 2.16.32.1.4.0.230.0.80.32.0.0.0.0.0.0.0.0 (1 means IPv6, 16 octets, rest needs formatting)
def str_format_ip_mib_entry_index(v)
    #make sure we have a value
    return if !v
    #strip leading and trailing whitespace
    v = v.strip
    #split by dots
    v_parts = v.split(".")
    #must have at least 6 parts to be valid
    return if v_parts.length() < 6
    #get address type 
    addr_type = v_parts.shift().to_i
    #don't need octets for anything so discard - v4 is always 4 and v6 is always 16
    v_parts.shift()
    #Figure out what to do based on the address type
    if addr_type == 1 then
        #if its ipv4 then its easy, just list separated by dots (addrtype 1 is IPv4)
        return if v_parts.length() != 4
        v = v_parts.join('.')
    elsif addr_type == 2 then
        #if its ipv6 then get out of dotted notation and make look like ipv6 (addrtype 2 is IPv6)
        #use long form notation since easiest and elastic will normalize
        return if v_parts.length() != 16
        ipv6_str = ""
        (0..15).step(1) do |i|
            #add separator every other iteration
            if i != 0 && (i % 2) == 0 then
                ipv6_str.concat(":")
            end
            #convert to hex string with leading 0s
            ipv6_str.concat(v_parts[i].to_i.to_s(16).rjust(2, "0"))
        end
        v = ipv6_str
    end
    #there are other address types for link local, etc but we don't care about those

    return v
end

def to_type(v, type, v_spec={})
    is_num = false
    if type == "float" then
        #this will set to 0.0 if parsing fails
        v = v.to_f
        if !v_spec["scale"].nil? then
            v = v * v_spec["scale"].to_f
        end
        is_num = true
    elsif type == "int" || type == "integer" then
        #this will set to 0 if parsing fails
        v = v.to_i
        if !v_spec["scale"].nil? then
            v = v * v_spec["scale"].to_i
        end
        is_num = true
    elsif type == "bool" || type == "boolean" then
        #if this is a regex match, set to true if matches and false otherwise
        if v_spec["regex"] then
            if v.match(v_spec["regex"]) then
                v = true
            else
                v = false
            end
        else
            #this will set to false if not common form of true
            v = to_boolean(v)
        end
    elsif type == "str" || type == "string" then
        v = v.to_s
        #apply built-in formatter
        if v_spec["format"] then
            if v_spec["format"] == "tmnxportid" then
                #parse port id int and convert to name per timetra spec
                v = TmnxPortId.decode(v)
            elsif v_spec["format"] == "tmnxsapid" then
                #parse sap id in form prefix.portid.suffix and convert to prefix-portname-suffix
                v = TmnxPortId.decode_sap(v)
            elsif v_spec["format"] == "ip_mib_entry_index" then
                #parse index from IP-MIB in format ADDR_TYPE.NUM_OCTETS.DOTTED_IP
                v = str_format_ip_mib_entry_index(v)
            else
                logger.error("Invalid value spec string format specified #{v_spec['format']}")
            end
        end

        #apply regex - use either a gsub string or a group. default is group with value 1 unless 'default' specified
        if v_spec["regex"] then
            if v_spec["gsub"] then
                #do replacement - backreferences take form \\1, \\2, etc
                v = v.gsub(v_spec["regex"], v_spec["gsub"])
            elsif matches = v.match(v_spec["regex"]) then
                group = 1
                if !v_spec["group"].nil? then
                    group = v_spec["group"].to_i
                end
                if matches.length() > group then
                    v = matches[group]
                end
            elsif v_spec["default"] then
                #if default then use that
                v = v_spec["default"]
            else
                #otherwise set to empty string
                v = ""
            end
        end

        #translate if given translate map
        if v_spec["translate"] && v_spec["translate"].kind_of?(Hash) then
            if v_spec["translate"].key?("#{v}") then
                v = v_spec["translate"]["#{v}"]
            elsif v_spec["translate"].key?("default") then
                v = v_spec["translate"]["default"]
            end
        end
    else
        logger.error("Invalid type in value list #{type}")
    end

    return [v, is_num]
end

def rate_put(prefix, id, time, v)
    k = key_builder(prefix, id, time)
    RateCache.put(k, v)
    #logger.info("Rate cache stats #{RateCache.stats()}")
    #logger.info("Rate cache size #{RateCache.size()}")
end

def rate_get(prefix, id, time, type)
    k = key_builder(prefix, id, time)
    result = RateCache.get(k)
    if result && result.key?("ts") && result.key?("v") then
        logger.debug("got rate bin", "key" => k, "result" => result)
        (converted_val, is_num) = to_type(result["v"], type)
        result["ts"] = result["ts"].to_i
        result["v"] = converted_val
        ##
        # Remove key to prevent cache from growing too big -particularly in backlog
        # New cache entry will become the best starting point for future rates
        RateCache.delete(k)
        return result
    else
        logger.debug("Unable to find key #{k}")
    end

    return
end

def key_builder(prefix, id, time)
    return "rate:#{prefix}:#{id}:#{time}"
end

# Expands a string containing logstash-like field refs in form %{field_name}
def format_pattern_str(pattern_str, event) 
    #validate
    if pattern_str.nil? || event.nil? then
        return
    end

    #iterate over variables to replace
    # create new string so we don't mess with scan
    formatted_str = pattern_str
    pattern_str.scan(/(%{(.+?)})/) do |match|
        #match has two groups: 0 = full match, 1 = just the var name
        match_val = event.get(match[1])
        next if match_val.nil?
        formatted_str = formatted_str.sub(match[0], match_val)
    end

    return formatted_str
end

def parse_vspec(v_spec, event, raw_time, interval, bucket_time, bucket_prefix_field)
    #make sure we have a valid object
    if v_spec.nil? || !v_spec.is_a?(Hash) then
        logger.debug("Value in list is nil or not a hash")
        return
    end

    #check for required source field and get value
    if !v_spec.key?("source") || v_spec["source"].nil? then
        logger.debug("Value in list is missing source")
        return
    end

    #if we have no value then skip
    v = event.get(v_spec["source"])
    if v.nil? then
        return
    end

    return parse_v(v, v_spec, event, raw_time, interval, bucket_time, bucket_prefix_field)
end

def parse_v(v, v_spec, event, raw_time, interval, bucket_time, bucket_prefix_field)
    
    #get target or default to source if not set.
    if v_spec.key?("target") && v_spec["target"] then
        target = v_spec["target"]
    elsif v_spec.key?("target_pattern") && v_spec["target_pattern"] then
        target = format_pattern_str(v_spec["target_pattern"], event)
    elsif v_spec.key?("source") && v_spec["source"] then
        target = v_spec["source"]
    else 
        logger.debug("No target set (or source fallback) so can't set target")
        return
    end
    # make sure target has opening and closing square brackets so can concatenate values later
    if target !~ /\[.+\]/ then
        target = "[#{target}]"
    end

    #get type or default to string
    type = "string"
    if v_spec.key?("type") && v_spec["type"] then
        type = v_spec["type"].downcase
    end
    
    #if its a list type then process each item in the list
    if type == "list"
        #The items field is what gives us specs for individual items
        if v_spec.key?("items") && v_spec["items"] then
            v_index = 0
            #Iterate through each value in list
            Array(v).each do |i|
                #Iterate through items
                #items can be a single object or array. A list is useful when 
                #working with arrays of objects and want to extract individual fields
                Array(v_spec["items"]).each do |i_spec|
                    #initialize a new speecification for this item that will be used 
                    #to recursively call this function later
                    new_vspec = { "type" => i_spec["type"] }

                    # Get the field name or default to 'field'
                    field_name = "field"
                    if i_spec.key?("field_name") && i_spec["field_name"] then
                        field_name = i_spec["field_name"]
                    end
                    
                    #Field index can either come from a field relative to value or defaults to array position
                    field_index = v_index
                    if i_spec.key?("field_index") && i_spec["field_index"] then
                        field_index = get_json_field(i, i_spec["field_index"])
                        if field_index.nil? then
                            next
                        end
                    end

                    #Now we can create the id (i.e. cache key) and target field. Not necessarily required if not doing calcs.
                    if v_spec.key?("id") && v_spec["id"] && i_spec.key?("id") && i_spec["id"] then
                        new_vspec["id"] = "#{v_spec['id']}:#{field_name}_#{field_index}:#{i_spec['id']}"
                    end
                    
                    # Create target - can be optional if want to overwrite source. 
                    if v_spec.key?("target") && v_spec["target"] && i_spec.key?("target") && i_spec["target"] then
                        new_vspec["target"] = "#{v_spec['target']}[#{field_name}_#{field_index}]#{i_spec['target']}"
                    end

                    #parse the source 
                    new_v = i
                    if i_spec.key?("source") && i_spec["source"] then
                        new_v = get_json_field(new_v, i_spec["source"])
                        if new_v.nil? then
                            next
                        end
                    end

                    #Pass the new value and spec to this function recursively
                    logger.debug("Processing list item", "new_v" => new_v, "new_vspec" => new_vspec)
                    parse_v(new_v, new_vspec, event, raw_time, interval, bucket_time, bucket_prefix_field)
                end
                v_index += 1
            end
        else
            logger.debug("List type has no items so skipping", "target" => target)
        end

        return
    end

    #determine if we should calculate per second rate
    no_rate = false
    if v_spec.key?("no_rate") && v_spec["no_rate"] then
        no_rate = true
    end

    #determine if we should calculate delta
    no_delta = false
    if v_spec.key?("no_delta") && v_spec["no_delta"] then
        no_delta = true
    end

    #determine if we allow negative deltas
    allow_negative_delta = false
    if v_spec.key?("allow_negative_delta") && v_spec["allow_negative_delta"] then
        allow_negative_delta = true
    end

    #convert to type
    v, is_num = to_type(v, type, v_spec)

    #set val field in target
    event.set("#{target}[val]", v)

    #determine if conditions met to calculate a rate - separate for better error messages
    if !is_num then
        logger.debug("Value is not numeric so skipping calculations", "target" => target)
        return
    end
    if no_rate && no_delta then
        logger.debug("Rate and delta calculations disabled by options", "target" => target)
        return
    end
    if !event.get(bucket_prefix_field) then
        logger.debug("Cannot find bucket_prefix_field in event", "bucket_prefix_field" => bucket_prefix_field, "target" => target)
        return
    end
    if !(v_spec.key?("id") && v_spec["id"]) then
        logger.debug("Missing id in script_params 'values' object", "target" => target)
        return
    end

    #If we statically set a starting point (like a counter we know resets every time) use that, otherwise hit cache
    prev_bin = nil
    if v_spec.key?("delta_start") then
        prev_bin = {
            "ts" => bucket_time - interval,
            "v" => v_spec["delta_start"]
        }
    else
        #store in cache
        prefix = event.get(bucket_prefix_field)
        rate_put(prefix, v_spec["id"], bucket_time, {"ts" => raw_time, "v" => v})
        #get previous bin
        prev_bin = rate_get(prefix, v_spec["id"], bucket_time - interval, type)
    end

    #Calculate delta and rates
    if !prev_bin.nil? then
        #calulate delta
        delta = v - prev_bin["v"]
        #check for counter resets
        if delta < 0 && !allow_negative_delta then
            event.set("#{target}[reset]",true)
            return
        end
        #set delta if we want it
        if !no_delta then
            event.set("#{target}[delta]",delta)
        end
        #calculate per second rate
        if !no_rate then
            time_diff = raw_time - prev_bin["ts"]
            if time_diff > 0 then
                event.set("#{target}[rate]", delta.to_f/time_diff.to_f)
            end
        end
    end
end