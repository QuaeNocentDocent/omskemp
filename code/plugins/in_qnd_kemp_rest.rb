#!/usr/local/bin/ruby

require 'fluent/input'

module Fluent

  class QNDKempRestInput < Input
    Fluent::Plugin.register_input('qnd_kemp_rest', self)

    def initialize
      super
      require_relative 'kemp_lib'
    end

#improvements, we must be able to differentiate intervals for data collection based on type
#for example device type can be acolecetd once a day, performances every 60" and state every 300"

    config_param :interval, :time#, default: 4h
    config_param :interval_perf, :time#, default: 30s
    config_param :interval_status, :time#, default: 5m
    config_param :tag, :string 
    config_param :nodes, :array, value_type: :string
    config_param :user_name, :string
    config_param :user_password, :string, secret: true
    config_param :retries, :integer, default: 3
    config_param :wait_seconds, :integer, default: 2  
    # Interval in seconds to refresh the cache
    config_param :ip_cache_refresh_interval, :integer, :default => 600
    config_param :counters_map, :array, :default => [
      {:object=>'Processor', :instance=>'_Total', :selector=>'CPU.total', :counters => [
          {:counter=>'% System Time', :value=>'System'},
          {:counter=>'% User Time',  :value=>'User'},
          {:counter=>'IO Waiting',  :value=>'IOWaiting'},
        ]
      },
      {:object=>'Memory', :instance=>'_Total',  :selector=>'Memory', :counters=>[ 
          {:counter=>'% Used', :value=>'percentmemused'},
          {:counter=>'Used KB', :value=>'memused'},
          {:counter=>'Free KB', :value=>'memfree'}
        ]
      },      
      {:object=>'Network', :instance=>'*',  :selector=>'Network.*', :counters=>[ 
          {:counter=>'in bytes/sec', :value=>'*.inbytes'},
          {:counter=>'out bytes/sec', :value=>'*.outbytes'},
          {:counter=>'% bandwidth in', :value=>'*.in'},
          {:counter=>'% bandwidth out', :value=>'*.out'}
        ]
      },
      {:object=>'TPS', :instance=>'_Total',  :selector=>'TPS', :counters=>[ 
          {:counter=>'Total TPS', :value=>'Total'},
          {:counter=>'SSL TPS', :value=>'SSL'}
        ]
      },     
      {:object=>'VS', :instance=>'_Total', :selector=>'VStotals', :counters => [
        {:counter=>'Connections/sec', :value=>'ConnsPerSec'},
        {:counter=>'Bytes/sec', :value=>'BytesPerSec'}
        ]
      },        
      {:object=>'VS', :instance=>'*.Index', :selector=>'Vs.*', :counters => [
        {:counter=>'Active Connections', :value=>'*.ActiveConns'},
        {:counter=>'Connections/sec', :value=>'*.ConnsPerSec'}
        ]
      },
      {:object=>'RS', :instance=>'*.RSIndex', :selector=>'Rs.*', :counters => [
        {:counter=>'Active Connections', :value=>'*.ActiveConns'},
        {:counter=>'Connections/sec', :value=>'*.ConnsPerSec'}
        ]
      }      
    ]

    def configure (conf)
      super
       @ip_cache = OMS::IPcache.new @ip_cache_refresh_interval
       $log.debug {"Configuring Kemp rest plugin"}       
    end

    def start     
      $log.debug {"Starting Kemp rest plugin with interval #{@interval} and perf interval #{@interval_perf}"}
      super
      if @interval
        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
      else
        get_info_data
      end
      if @interval_perf
        @finished = false
        @perf_condition = ConditionVariable.new
        @perf_mutex = Mutex.new
        @perf_thread = Thread.new(&method(:run_periodic_perf))
      else
        get_perf_data
      end
      if @interval_status
        @finished = false
        @status_condition = ConditionVariable.new
        @status_mutex = Mutex.new
        @status_thread = Thread.new(&method(:run_periodic_status))
      else
        get_status_data
      end
    end

    def shutdown
      if @interval
        @mutex.synchronize {
          @finished = true
          @condition.signal
        }
        @thread.join
      end
      if @interval_perf
        @perf_mutex.synchronize {
          @finished = true
          @perf_condition.signal
        }
        @perf_thread.join
      end      
      if @interval_status
        @status_mutex.synchronize {
          @finished = true
          @status_condition.signal
        }
        @status_thread.join
      end       
      super
    end

    def decorate_record(record,type,time,name)
        record["rType"]=type
        record["EventTime"] = OMS::Common.format_time(time)
        record["Computer"] = name
        record["HostIP"] = "Unknown IP"         
        host_ip = @ip_cache.get_ip(name)
        if host_ip.nil?
            OMS::Log.warn_once("Failed to get the IP for #{name}.")
        else
          record["HostIP"] = host_ip
        end
        record
    end

    def get_status_data
      #time = Time.now.to_f
      time = Engine.now

      #multi stream snippet follwowing, for consistency we will follow other OMS plugins
      #es = MultiEventStream.new
      #@nodes.each {|name|
      #  $log.debug {"Calling device_info for #{name} with time #{time}"}
      #   record=KempRest::KempDevice.device_info(name, @user_name, @user_password, @retries, @wait_seconds)
      #   es.add(time,record) unless record.nil?
      #}
      #tag= @tag + '.info'
      #$log.debug {"returning #{tag} data"}
      #router.emit_stream(tag, es) unless es.empty?
      #the format used by OMS is a little different they alway return one record that wraps many records
      #wrapper = {
      #   "DataType"=>"HEALTH_ASSESSMENT_BLOB",
      #   "IPName"=>"LogManagement",
      #   "DataItems"=>[data_item]
      #}
      # router.emit(@tag, time, wrapper) if wrapper

      #class needs to be improved with caching, persitent node context etc
      kdevice= KempRest::KempDevice.new
      kdevice.retries=@retries
      kdevice.wait_secs=@wait_seconds
      #OMS consistent data, mettici un rescue
      #records=[]
      es=MultiEventStream.new
      #record= {"servertype"=>"rs","index"=>"118","parentindex"=>"43","name"=>"","parentname"=>"ws-di-btiissole.asmn.net",
      #  "status"=>"Up","address"=>"172.20.3.127","enabled"=>"Y","rType"=>"device_status","EventTime":"2016-12-08T09:29:00.453Z",
      #  "Computer"=>"smv-inf-kemp1b.asmn.net","HostIP"=>"172.20.2.72"}
      #es.add(time,record)
      @nodes.each {|name|
        $log.trace {"Calling vsrs_status for #{name} with time #{time}"}
         #let's set status here before moving it in its own method
         status = kdevice.vsrs_status(name, @user_name, @user_password)
         unless status.empty?
           status.each {|record|
              record = decorate_record(record,'device_status',time,name)    
              $log.trace {"#{record}"}            
              es.add(time,record)
           }
         end
      }      
      if es.empty? #records.count == 0 
        $log.warn {"No data returned for vsrs_status"}
      else
        #router.emit(@tag, time, records)

        router.emit_stream(@tag,es)
      end
    end

    def get_info_data
      #time = Time.now.to_f
      time = Engine.now

      #multi stream snippet follwowing, for consistency we will follow other OMS plugins
      #es = MultiEventStream.new
      #@nodes.each {|name|
      #  $log.debug {"Calling device_info for #{name} with time #{time}"}
      #   record=KempRest::KempDevice.device_info(name, @user_name, @user_password, @retries, @wait_seconds)
      #   es.add(time,record) unless record.nil?
      #}
      #tag= @tag + '.info'
      #$log.debug {"returning #{tag} data"}
      #router.emit_stream(tag, es) unless es.empty?
      #the format used by OMS is a little different they alway return one record that wraps many records
      #wrapper = {
      #   "DataType"=>"HEALTH_ASSESSMENT_BLOB",
      #   "IPName"=>"LogManagement",
      #   "DataItems"=>[data_item]
      #}
      # router.emit(@tag, time, wrapper) if wrapper

      #class needs to be improved with caching, persitent node context etc
      kdevice= KempRest::KempDevice.new
      kdevice.retries=@retries
      kdevice.wait_secs=@wait_seconds
      #OMS consistent data, mettici un rescue
      #records=[]
      es=MultiEventStream.new
      @nodes.each {|name|
        $log.trace {"Calling device_info for #{name} with time #{time}"}
         info=kdevice.device_info(name, @user_name, @user_password)
         unless info.empty?
            # use the tag to differentiate streams returned, in the end we will have a multistream payload with different wrappers
            #in case we need cleanup use /^[a..Z0..9 :]/         
            #record.each {|key,value| value.gsub!("\n","")}
            info=decorate_record(info,'device_info',time,name)
            $log.trace {"#{info}"}                     
            es.add(time,info)
            #records << record
         end
      }      
      if es.empty? #records.count == 0 
        $log.warn {"No data returned for KempDevice.device_info"}
      else
        #router.emit(@tag, time, records)

        router.emit_stream(@tag,es)
      end
    end


    def get_perf_data
      time = Time.now.to_f
      time = Engine.now
      #OMS consistent data
      kdevice= KempRest::KempDevice.new
      kdevice.retries=@retries
      kdevice.wait_secs=@wait_seconds
      #es=MultiEventStream.new
      records=[]
      @nodes.each {|name|
        $log.trace {"get_perf_data for #{name}"}
        perfs = kdevice.device_perf(name,@user_name, @user_password,@counters_map)
        $log.trace {"got perf data for #{name} - #{perfs.count}"}
        unless perfs.empty?
          perfs.each {|object|
            object['Timestamp']=OMS::Common.format_time(time)
            object['Host']=name
            object['ObjectName']=object.delete('ObjectName')
            object['InstanceName']=object.delete('InstanceName')
            object['Collections']=object.delete('Collections')
            #es.add(time,object) 
            records << object
          }
        end
      }
      if records.count == 0 # es.empty?
        $log.warn {"No data returned for get_perf_data"} if es.empty?
      else
        #debug let's try to pass a single record
        #records=[          
        #        {"Timestamp"=>"2016-12-07T07:55:40.000Z","Host"=>"smv-inf-kemp1a.asmn.net",
        #          "ObjectName"=>"KempLM-Processor","InstanceName"=>"_Total",
        #          "Collections":[{"CounterName"=>"% System Time","Value"=>1.0},{"CounterName"=>"% User Time","Value"=>2.0},{"CounterName"=>"IO Waiting","Value"=>0.0}]                  
        #        }
        #    ]
        wrapper = {
          "DataType"=>"LINUX_PERF_BLOB",
          "IPName"=>"LogManagement",
          "DataItems"=>records
        }
        router.emit(@tag, time, wrapper)
        #router.emit_stream(@tag, es) unless es.empty?
      end
    end


    def run_periodic
      @mutex.lock
      done = @finished
      until done
        @condition.wait(@mutex, @interval)
        done = @finished
        @mutex.unlock
        if !done
          get_info_data
        end
        @mutex.lock
      end
      @mutex.unlock
    end

    def run_periodic_perf
      @perf_mutex.lock
      done = @finished
      until done
        @perf_condition.wait(@perf_mutex, @interval_perf)
        done = @finished
        @perf_mutex.unlock
        if !done
          get_perf_data
        end
        @perf_mutex.lock
      end
      @perf_mutex.unlock
    end

    def run_periodic_status
      @status_mutex.lock
      done = @finished
      until done
        @status_condition.wait(@status_mutex, @interval_status)
        done = @finished
        @status_mutex.unlock
        if !done
          get_status_data
        end
        @status_mutex.lock
      end
      @status_mutex.unlock
    end
  end # QNDKempRestInput

end # module

