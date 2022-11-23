#
#NOTE: Function names must be unique to all files in the logstash pipeline
# even if this is the only file imported. Logstash seems to share imports across all filters.
#
$META_KEY_SEP = "::"

def meta_key_builder(table, key_list, event)
    if  !table || !event || !key_list || !key_list.kind_of?(Array) then
        return
    end
    key = table
    Array(key_list).each do |k|
        if event.get(k) then
            key += "#{$META_KEY_SEP}" + event.get(k).to_s
        else
            logger.debug("Unable to build key because missing #{k}")
            return
        end
    end
    return key
end

def relation_redis_set(k, v, exp, redis)
    result = redis.set(k, v)
    if result != "OK" then
        logger.error("Storing key in redis failed", "key" => k, "redis_result" => result)
    else
        logger.debug("Storing key in redis succeeded", "key" => k, "redis_result" => result)
        if !redis.expire(k, exp) then
            logger.error("Unable to set expires for key", "key" => k, "expires" => exp)
        end
    end
end

def meta_redis_write_hash(k, v_hash, exp, redis)
    #make sure we have a key
    if !k or k == "" then
        logger.debug("meta_redis_write_hash was not given a key")
        return
    end
    result = redis.hmset(k, v_hash)
    if result != "OK" then
        logger.error("Storing metadata hash in redis failed", "key" => k, "redis_result" => result)
    else
        logger.debug("Storing metadata hash in redis succeeded", "key" => k, "redis_result" => result)
        if !redis.expire(k, exp) then
            logger.error("Unable to set expires for metadata hash key", "key" => k, "expires" => exp)
        end
    end
end

def meta_redis_write_set(k, v, exp, redis)
    #make sure we have a key
    if !k or k == "" then
        logger.debug("meta_redis_write_set was not given a key")
        return
    end
    #don't do much error checking since lib returns false if already there
    #The zadd allows us to expire elements in set by setting the score to the timestamp
    # when we query we only ask for scores in the unexpired range.
    redis.zadd(k, Time.now.getutc.to_i, v)
    redis.expire(k, exp)
end

##
# Lookup the given data in a redis cache.
#   key: Takes a list of key_functions as parameters 
#       and stores previous lookups in [@metadata][mlookup_cache_prev]. 
#       All lookups but the last should be a string. The last should be a hash.
def mlookup_cache(event, params, redis)
    #validate parameters
    kfs = params["key"]
    if !kfs || !kfs.kind_of?(Array) then
        logger.error("No key function list config provided to metadata cache lookup, so skipping")
        return [event]
    elsif event.nil? then
        logger.error("No event for mlookup_cache")
        return
    end
    if params["type"] == "set" && !params["target_name"] then
        logger.error("No target_name  config provided to metadata cache lookup of type set, so skipping")
        return [event]
    end

    #iterate through key functions
    key = nil
    Array(kfs).each do |kf|
        #If previous key, lookup in relation cache
        if key then
            event.set("[@metadata][mlookup_cache_prev]", redis.get(key))
        end
        #get the key
        key = key_function(kf["name"], event, kf["function"], redis)
        #if no key then return
        if !key then
            logger.debug("unable to determine key in mlookup_cache")
            return
        end
    end

    #For last key, lookup metadata based on type
    metadata = nil
    if params["type"] == "set" then
        #get member expiration (in seconds) with default of 24 hours
        mem_exp = 86400
        if params["expires"] then
            mem_exp = params["expires"].to_i
        end
        # lookup by zrange where min is now - expires
        score_min = Time.now.getutc.to_i - mem_exp
        result = redis.zrangeByScore(key, "#{score_min}", "+inf")
        if result && !result.empty? then
            #key in format type__name to match what is in hash and allow for non-string sets
            metadata = { "#{params['target_name']}" => result }
        end
    else
        #by default return a hash
        metadata = redis.hgetAll(key)
    end

    return metadata
end

##
# Get the given field from the passed object
#   field: The field to return as string
def kf_field(event, params)
    if !params["source"] then
        logger.error("field key function provided that is missing source")
        return
    end
    if !params["type"] then
        #default to string type
        params["type"] = "str"
    end
    #Get value
    v = event.get(params["source"])
    if !v.nil? then
        #first do type conversion in case any additional formatting options
        v, is_num = to_type(v, params["type"], params)
    else
        return
    end
    #if didn't get v then next
    if v.nil? then
        return
    end

    return v.to_s
end


##
# Apply regex to field and return specified capture group
# params:
#   field: The field to parse
#   regex: The regex to apply. Should have at least one capture group
#   group: The capture group to return. Default is 1. 
def kf_regex_group(event, params)
    #param parsing
    if !params.key?("field") || !params["field"] then
        logger.error("No field in regex_group params", "params"=>params)
        return
    end
    if !params.key?("regex") || !params["regex"] then
        logger.error("No regex in regex_group params", "params"=>params)
        return
    end
    group = 1
    if params.key?("group") && params["group"] then
        group = params["group"]
    end

    #apply regex
    field_val = event.get(params["field"])
    logger.debug("key_function params", "params" => params, "field_val" => field_val)
    if field_val && matches = field_val.match(params["regex"]) then
        logger.debug("key_function matches", "matches" => matches)
        if matches.length() > group then
            return matches[group]
        end
    end

    return
end

##
# Get the field by doing a lookup in a relation map
#   field: The field to return as string
def kf_relation(event, params, redis)
    #validation 
    if !params.key?("fields") || !params["fields"] then
        logger.error("No fields in field key_function params", "params"=>params)
        return
    end
    if !params.key?("name") || !params["name"] then
        logger.error("No name in field key_function params", "params"=>params)
        return
    end
    #build key and lookup in redis
    rel_k = meta_key_builder(params["name"], params["fields"], event)
    return redis.get(rel_k)
end

##
# Generaly function to map key_function definition to function above
def key_function(table_name, event, key_function, redis)
    #check fields
    if table_name.nil? then
        logger.error("No table_name for key_function", key_function => key_function)
        return
    elsif key_function.nil? then
        logger.error("No spec for key_function #{table_name}")
        return
    elsif event.nil? then
        logger.error("No event for key_function #{table_name}")
        return
    end

    #get type
    if !key_function.key?("type") || !key_function["type"] then
        logger.error("No type specified for key_function #{table_name}", key_function => key_function)
        return
    end

    #determine type function and pass params
    type = key_function["type"].downcase
    result = nil
    if type == "regex_group" then
        result = kf_regex_group(event, key_function["params"])
    elsif type == "field" then
        result = kf_field(event, key_function["params"])
    elsif type == "relation" then
        result = kf_relation(event, key_function["params"], redis)
    else
        logger.error("Unrecognized type #{type}", key_function => key_function)
        return 
    end

    #Make sure we have a valid key (not "" evals to truee in ruby)
    if !result or result == "" then
        return
    end

    #get parent objects for building key
    parents = []
    if key_function.key?("parents") && key_function["parents"] then
        parents = key_function["parents"]
    end

    #build key
    key = ""
    if table_name && !table_name.empty? then
        key = "#{table_name}#{$META_KEY_SEP}"
    end
    Array(parents).each do |parent_field| 
        parent = event.get(parent_field)
        if parent then
            key.concat("#{parent}#{$META_KEY_SEP}")
        end
    end
    key.concat("#{result}")
    
    return key
end

def key_function_multi(table_name, event, key_functions, redis)
    #iterate through key 
    key = nil
    Array(key_functions).each do |kf|
        # give table name as empty string. will append to last key later
        key = key_function("", event, kf, redis)
        if key && !key.empty? then
            event.set("[@metadata][mlookup_cache_prev]", key)
            #if find_or_continue set and we found, then done looping
            break if kf['find_or_continue'] 
        elsif kf['find_or_continue'] then
            #didn't find so settings say try the next one
            next
        else
            #otherwise if not found then we are done
            break
        end
    end
    #if we have a key and a table name, append the table name
    if key && !key.empty? && table_name && !table_name.empty? then
        key = "#{table_name}#{$META_KEY_SEP}#{key}"
    end

    return key
end