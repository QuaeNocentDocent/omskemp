module Fluent
  class KempFilter < Filter

    Fluent::Plugin.register_filter('filter_qnd_kemp_rest', self)

    def initialize
      super
      require 'socket'
      require_relative 'omslog'
      require_relative 'oms_common'
    end

    # Interval in seconds to refresh the cache
    config_param :ip_cache_refresh_interval, :integer, :default => 300

    def configure(conf)
      super
      @ip_cache = OMS::IPcache.new @ip_cache_refresh_interval
    end

    def start
      super
    end

    def shutdown
      super
    end

    def filter(tag, time, record)
      # Use Time.now, because it is the only way to get subsecond precision in version 0.12.
      # The time may be slightly in the future from the ingestion time.

      #the filter implements splitting logic for different data returned by the in_qnd_kemp_rest filter        
      #record={
      #    "DataType"=>"KEMP_DEVICE_INFO",
      #    "IPName"=>"LogManagement",
      #    "DataItems" => records
      #  }

      case record["DataType"] 
      when "KEMP_DEVICE_INFO"
        record["Timestamp"] = OMS::Common.format_time(Time.now.to_f)
        record["EventTime"] = OMS::Common.format_time(time)
        record["Computer"] = record["hostname"]
        record["HostIP"] = "Unknown IP"
        tag += '.info'
        host_ip = @ip_cache.get_ip(hostname)
        if host_ip.nil?
            OMS::Log.warn_once("Failed to get the IP for #{hostname}.")
        else
          record["HostIP"] = host_ip
        end
        
      else
          $log.warning {"DataType #{record['DataType']} not yet implemented, data is discarded"}
      end
      record["Timestamp"] = OMS::Common.format_time(Time.now.to_f)
      record["EventTime"] = OMS::Common.format_time(time)
      hostname = record["host"]
      record["Host"] = hostname
      record.delete "host"
      record["HostIP"] = "Unknown IP"

      host_ip = @ip_cache.get_ip(hostname)
      if host_ip.nil?
          OMS::Log.warn_once("Failed to get the IP for #{hostname}.")
      else
        record["HostIP"] = host_ip
      end

      if record.has_key?("pid")
        record["ProcessId"] = record["pid"]
        record.delete "pid"
      end

      # The tag should looks like this : qnd.syslog.kemp.authpriv.notice
      tags = tag.split('.')
      if tags.size == 5
        record["Facility"] = tags[3]
        record["Severity"] = tags[4]
      else
        $log.error "The syslog tag does not have 4 parts #{tag}"
      end

      regexp_stats=Regexp.new("(?<type>.*)status:\\D+(?<total>\\d+)\\D+(?<up>\\d+)\\D+(?<down>\\d+)\\D+(?<disabled>\\d+)")
      result=regexp_stats.match(record["message"])
      if !result.nil?
        #let's try to transform this in a perf data point

        #log way commented out
        #record["StatType"] = result["type"]
        #record["Total"] = Integer(result["total"]) rescue nil
        #record["Up"] = Integer(result["up"]) rescue nil
        #record["Down"] = Integer(result["down"]) rescue nil
        #record["Disabled"] = Integer(result["disabled"]) rescue nil                
        #record["Message"] = record["message"] #to be removed
        #end of comment, ruby is really ugly with comments!!
        #for sure there's a better and more elegant way to do this in ruby, too bad I don't know it
        data_items = []

        data_info = {}
        data_info["Timestamp"] = record["Timestamp"]
        data_info["Host"] = record["Host"]
        object_name = result["type"]
        data_info["ObjectName"] = "KempLM-#{object_name}"
        data_info["InstanceName"] = "_Total"
        counters=[]
        counter_pair = {}       
        counter_pair["CounterName"]="Total"
        counter_pair["Value"]=Integer(result["total"]) rescue nil
        counters.push(counter_pair)
        counter_pair = {}       
        counter_pair["CounterName"]="Up"
        counter_pair["Value"]=Integer(result["up"]) rescue nil
        counters.push(counter_pair)
        counter_pair = {}       
        counter_pair["CounterName"]="Down"
        counter_pair["Value"]=Integer(result["down"]) rescue nil
        counters.push(counter_pair)
        counter_pair = {}       
        counter_pair["CounterName"]="Disabled"
        counter_pair["Value"]=Integer(result["disabled"]) rescue nil
        counters.push(counter_pair)

        data_info["Collections"] = counters
        data_items.push(data_info)

        wrapper = {
          "DataType"=>"LINUX_PERF_BLOB",
          "IPName"=>"LogManagement",
          "DataItems"=>data_items
        }
        polyResult=wrapper
      else
        record["Message"] = record["message"]
        record.delete "message"
        polyResult = record
      end 
 
    polyResult
    end
  end
end
