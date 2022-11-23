#Require every jar from the maven directory
folder = '/usr/lib/stardust/pipeline/java/maven/'
Dir["#{folder}/**/*.jar"].each { |jar| require jar }

#import classes we want to use
java_import 'redis.clients.jedis.JedisPool'
java_import 'redis.clients.jedis.JedisPoolConfig'
java_import 'java.time.Duration'

class RedisPool
    #Connection pool settings. See https://javadoc.io/doc/redis.clients/jedis/latest/index.html
    @@config = Java::RedisClientsJedis::JedisPoolConfig.new()
    @@config.setMaxTotal(ENV['REDIS_CLIENT_POOL_SIZE'].to_i)
    @@config.setMaxIdle(ENV['REDIS_CLIENT_POOL_MAX_IDLE'].to_i)
    #unit is seconds for setMaxWait
    @@config.setMaxWait(Duration.ofSeconds(ENV['REDIS_CLIENT_POOL_MAX_WAIT'].to_i))

    #Connects to URL specified by environment variable REDIS_URL 
    @@redis = Java::RedisClientsJedis::JedisPool.new(@@config, ENV['REDIS_URL'])

    def self.get()
        return @@redis.getResource()
    end

    def self.finalize(resource)
        if not resource.nil? then
            resource.close()
        end
    end
end