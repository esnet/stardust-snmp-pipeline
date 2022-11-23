#Require every jar from the maven directory
folder = '/usr/lib/stardust/pipeline/java/maven/'
Dir["#{folder}/**/*.jar"].each { |jar| require jar }

#import classes we want to use
java_import 'com.github.benmanes.caffeine.cache.LoadingCache'
java_import 'java.time.Duration'

class RateCache
    #Instantiate cache
    @@cache = Java::ComGithubBenmanesCaffeineCache::Caffeine.newBuilder().maximumSize(ENV['RATE_CACHE_MAX_ENTRIES'].to_i).expireAfterWrite(Duration.ofSeconds(ENV['RATE_CACHE_EXPIRES'].to_i)).build()

    def self.get(k)
        return @@cache.getIfPresent(k)
    end

    def self.put(k, v)
        @@cache.put(k, v)
    end

    def self.delete(k)
        @@cache.invalidate(k)
    end

    def self.stats()
        return @@cache.stats()
    end

    def self.size()
        return @@cache.estimatedSize()
    end

end