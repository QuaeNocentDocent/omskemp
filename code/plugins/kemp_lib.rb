module KempRest

require 'net/http'
require 'net/https'
require 'multi_xml'
require 'uri'
require 'logger'
require 'time'
require 'date'

require_relative 'oms_common'



class KempDevice

  #Open points
#- shell I use instance methods instead of class methods? The former are useful if I implement some sort of caching. So let's start with class methods and revert to instance methods once we have caching

    attr_accessor :timeout
    attr_accessor :retries
    attr_accessor :wait_secs
    @@log =  Logger.new(STDERR) #nil
    @@log.formatter = proc do |severity, time, progname, msg|
        "#{time} #{severity} #{msg}\n"
    end


    def initialize(refresh_interval_seconds=60)
      @timeout=30
      @retries=3
      @wait_secs=2
      @vs_map={}
      @subvs_map={}
      @rs_map={}

      #let's leave some sync objects here but basically do nothing in this version
      @cache_lock = Mutex.new
      @refresh_interval_seconds = refresh_interval_seconds
      @condition = ConditionVariable.new
      @thread = Thread.new(&method(:refresh_cache))
      
    end

  def parse_counter(counters_hash, selector, instance, counter_label, value)
  #returns instance and value if found
  #selector is a dotted list of path, the last one can be a *, in this case instance si the relative path starting from the previous node and value must be get of every instance

    keys=selector.split('.')
    multi=false
    if keys.last == '*' 
      keys.delete(keys.last)
      multi=true
    end

    sub_hash = counters_hash.dup  
    keys.each {|key| sub_hash=sub_hash[key]}
    result={}
    if multi
      instance_keys = instance.split('.')
      value_keys = value.split('.')
      raise "Invalid instance or value selector #{instance}:#{value}" if instance_keys.first != '*' || value_keys.first != '*'
      value_keys.delete(value_keys.first)      
      instance_keys.delete(instance_keys.first)

      if instance_keys.empty?      
        sub_hash.each {|key, cvalue|
          #result[key]=[] unless result.has_key?(key)
          result[key] = {'CounterName'=>counter_label, 'Value' => cvalue[value_keys[0]].to_f}
        }
      else
        if ! sub_hash.is_a?(Array) then sub_hash=[sub_hash] end
        sub_hash.each {|element|
          instance = element.dup
          value = element.dup
          instance_keys.each {|key| instance=instance[key]}
          value_keys.each {|key| value=value[key]}
          #result[instance]=[] unless result.has_key?(instance)
          result[instance] = {'CounterName'=>counter_label, 'Value'=>value.to_f}
        }


      end
    else
      #result[instance]=[]
      result[instance] = {'CounterName'=>counter_label, 'Value'=>sub_hash[value].to_f} #unless sub_hash[value].nil?
    end

    result
  end

  def format_time(date_string)
    #this format is safe for OMS and the to_msgpack method if not you getr errors stating the method is not defined in out_oms_api plugin
    begin
      res=Time.at(DateTime.parse(date_string).to_time).utc.iso8601(3)
    rescue
      @@log.warn {"failed to convert #{date_string} to UTC time setting a default"}
      res = Time.utc(2000,1,1).iso8601(3)
    end
    res
  end

  def device_info (name, user_name, user_password)
    #tbd. create a data structure with cvommands and props to make the info gathering flexible
    props=['dfltgw', 'hamode', 'havhid', 'hastyle','backupenable','backuphost','ha1hostname','hostname','ha2hostname','serialnumber','version']

    #for ha1hostname better a regexp
    @@log.debug {"device_info: getting data for #{name}"}
    device_info = access_get(name, user_name, user_password, 'getall')
    results={}
    unless device_info.nil?
      results = device_info['Response']['Success']['Data'].select {|tag, value| props.include?(tag)}
    end
    #now get licesning info
    props=['uuid', 'LicensedUntil', 'SupportUntil', 'LicenseType','LicenseStatus','ActivationDate','ApplicaneModel','ApplianceModel']    
    @@log.debug {"device_info: getting license info for #{name}"}
    device_info = access_get(name, user_name, user_password, 'licenseinfo')
    unless device_info.nil?
      results.merge!(device_info['Response']['Success']['Data'].select {|tag, value| props.include?(tag)})
    end
    #some translation here for the AppicaneModel properties to correct a typo in Kemp interface
    if ! results['ApplicaneModel'].nil?
        results['ApplianceModel'] = results.delete('ApplicaneModel')
    end
    #cleanup and convert
    #nyi excpetion management during conversion    
    props.each {|p| results[p].gsub!(/[^0-9A-Za-z :]/, '') unless results[p].nil?}
    ['ActivationDate','SupportUntil'].each {|p| results[p]=format_time(results[p]) unless results[p].nil?}
    results['LicensedUntil'] = results['LicensedUntil'] == 'unlimited' ? format_time('01-01-2099') : format_time(results['LicensedUntil'])
     
    #finally get if an HSM is installed
    props=['engine']
    @@log.debug {"device_info: getting HSM info for #{name}"}
    device_info = access_get(name, user_name, user_password, 'showhsm')
    unless device_info.nil?
      results.merge!(device_info['Response']['Success']['Data']['HSM'].select {|tag, value| props.include?(tag)})
    end
    #some translation here for the AppicaneModel properties to correct a typo in Kemp interface
    if results['engine']
        results['hsmengine'] = results.delete('engine')
    end
    
    results
  end

  def vsrs_status(name, user_name, user_password)
    #return an array of hash
    # 'type': vs|rs|subvs
    # 'index':
    # 'parentindex': nil for vs
    # 'name'
    # 'parentname'
    # 'status'
    # 'address' 
    load_maps(name,user_name,user_password)
    results=[]
    @vs_map.each {|key, value|
      results.push (
        {'servertype':'vs', 'index'=>key, 'parentindex'=>'', 'name'=>value[:name], 'parentname'=>'', 'status'=>value[:status], 'address'=>'', 'enabled'=>value[:enable]}
      )
    }
    @subvs_map.each {|key, value|
      parent_name = get_vsinfo(value[:vsindex], :name)
      results.push (
        {'servertype':'subvs', 'index'=>key, 'parentindex'=>value[:vsindex], 'name'=>value[:name], 'parentname'=>parent_name, 'status'=>value[:status], 'address'=>'', 'enabled'=>value[:enable]}
      )
    }    
    @rs_map.each {|key, value|
      parent_name = get_vsinfo(value[:vsindex], :name)
      results.push (
        {'servertype':'rs', 'index'=>key, 'parentindex'=>value[:vsindex], 'name'=>value[:name], 'parentname'=>parent_name, 'status'=>value[:status], 'address'=>value[:address], 'enabled'=>value[:enable]}
      )
    }
    results        
  end


  def device_perf (name, user_name, user_password,counters_map)

    #open points
    #- objects naming, shall I try to use standard names (like "Processor") or make it clear it's a Kemp object? In LA we don't have much status right now, just the Computer/Host name can join the counter to other data sets
    #- we must set meaningful naming for VS and RS instances, this means getting all the VSs and RSs, this should be cached
    #we must return an array of objects with the following pseduo schema
    #{
    #"Timestamp": {"type": "string"},
    #"Host": {"type": "string"},
    #"ObjectName": {"type": "string"},
    #"InstanceName": {"type": "string"},
    #"Collections": {
    #  "type": "array",
    #  "items": {
    #    "type": "object",
    #    "properties": {
    #      "CounterName": {"type": "string"},
    #      "Value": {"type": "number"}
    #    }
    #  }
    #}
    #}
    
    #this must be isolted in its own method
    #the listvs call returns all the vs once and all the subvs basically a subvs is listed twice as a subvs and as a vs
    #to keep generic let's gather evrything and then we will see if we need it
    @@log.debug {"device_perf: getting data for #{name}"}

    perf=access_get(name, user_name, user_password, 'stats')
    performance_points=[]
    unless perf.nil?
      perf = perf['Response']['Success']['Data']
      counters_map.each {|instance|
          instances={}
          instance[:counters].each {|counter| 
            #we can have very limited support for calculated counters:
            # - we support just + 
            # - calculated counters must be defined after the operands needed
            # - calculated counters must be contained in the same instance
            if (counter[:value][0] == '[') 
                new_counter = 0
                begin 
                  @@log.debug {"calculating counter #{counter[:counter]} with value #{counter[:value]}"}
                  operands=counter[:value].scan(/\[(.+?)\]/).flatten
                  @@log.debug {"Parsed value #{operands}"}
                  operands.each {|v|
                    @@log.debug {"Looking for #{v}"}     
                    instances[instance[:instance]].each {|c|
                      new_counter += c['Value'] if c['CounterName'] == v
                    }
                  } 
                rescue Exception => e
                  new_counter=nil
                  @@log.error {"error calculating counter #{counter[:counter]} #{e.message}"}
                end 
                # this to get the operators but we will manage them in future versions counter[:value].scan(/\](.)/).flatten
                # in the future we can substitute the values and use *eval* to evaluate the computation so that we can use any math ruby makes available
                counters={}
                counters[instance[:instance]] = {'CounterName'=>counter[:counter], 'Value'=>new_counter.to_f}
            else
              counters = self.parse_counter(perf, instance[:selector], instance[:instance], counter[:counter], counter[:value])
            end
            counters.each {|key, value|
                instances[key]=[] unless instances.has_key?(key)
                instances[key] << value
            }
          }
          instances.each {|key, value|
              performance_points << {'ObjectName' => instance[:object], 'InstanceName' => key, 'Collections' => value}
          }    
      }
    end
    load_maps(name,user_name, user_password)

    performance_points.each {|object|
      object_name =  object['ObjectName']
      object['ObjectName']="KempLM-#{object_name}"
      case object_name
      when 'VS'
        in_name = get_vsinfo(object['InstanceName'], :name)
        object['InstanceName'] = "#{object['InstanceName']} - #{in_name}" unless in_name.nil?      
        if in_name.nil? then @@log.info {"device_perf: no translation for VS Index #{object['InstanceName']}"} end
      when 'RS'
        rs_name = get_rsinfo(object['InstanceName'], :name)
        rs_name = (rs_name.nil? || rs_name.empty?) ? 'nyi' : rs_name
        rs_vsindex = get_rsinfo(object['InstanceName'], :vsindex)
        vs_name = get_vsinfo(rs_vsindex, :name) unless rs_vsindex.nil?
        vs_name = rs_vsindex if vs_name.nil?
        object['InstanceName'] = "#{object['InstanceName']} - #{rs_name} (#{vs_name})"
        @@log.info {"device_perf: no translation for RS Index #{object['InstanceName']}"} if rs_vsindex.nil?      
      end
    }

    performance_points
  end #device_perf

  private
    def access_get (name, user_name, user_password, command)    
      #@@log.debug {"device_rest: getting data for #{name}"}

      uri=URI("https://#{name}/access/#{command}")    
      req=Net::HTTP::Get.new(uri)
      req.basic_auth(user_name, user_password)
      http= Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl=true
      http.read_timeout=@timeout
      #more often than not Kemp devices use self signed certificates
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      result = nil
      retries=@retries
      begin
        response=http.request(req)
        result=MultiXml.parse(response.body) if response.code == '200'
      rescue => exception
        #log exception in some way
        retries-=1
        @@log.error { "device_rest: Error reading data #{exception} remaining retries #{retries}" }
        sleep(@wait_secs)
        retry if retries > 0
      else
        @@log.debug {"device_rest: got data without any glitch #{name}"}
      end
      result
    end   

    def load_maps(name, user_name, user_password)
      device_info = access_get(name, user_name, user_password, 'listvs')

      if device_info.nil?
          raise "Error getting VS list from #{name}"
      end
      #now we must build a VS and subVS hash, this should be cached
      #right now let's implement a ctach all
      begin
        device_info['Response']['Success']['Data']['VS'].each { |vs|    
          @vs_map[vs['Index']]={
            :address =>vs['VSAddress'],
            :name => vs['NickName'],
            :status => vs['Status'],
            :enable => vs['Enable']
          }    
          if ! vs['SubVS'].nil?
              subvs = vs['SubVS']
              if ! subvs.is_a?(Array) then subvs=[subvs] end
              subvs.each {|sub|
                @subvs_map[sub['VSIndex']]={
                  :address =>vs['VSAddress'],
                  :name => sub['Name'],
                  :vsindex => vs['Index'],
                  :status => sub['Status'],
                  :enable => vs['Enable']                  
                }               
              }          
          end  
          if ! vs['Rs'].nil?
              rs = vs['Rs']
              if ! rs.is_a?(Array) then rs=[rs] end
              rs.each {|r|
                @rs_map[r['RsIndex']]={
                  :address =>r['Addr'],
                  :name => '',
                  :vsindex => r['VSIndex'],
                  :status => r['Status'],
                  :enable => vs['Enable']                  
                }               
              }          
          end      
        }
        #now remove from the vs_map the sub_vs
        @subvs_map.each { |key, value|
          if ! @vs_map[key].nil? then @vs_map.delete(key) end
        }
        #no error handling right now
      rescue Exception => e
        @@log.error {"load_maps: error populating VS andRS maps #{e.message}"}
      end
    end

    def get_vsinfo(index, prop)
      @cache_lock.synchronize {
        if @vs_map.has_key?(index)
          return @vs_map[index][prop]
        else
          if @subvs_map.has_key?(index)
            return @subvs_map[index][prop]          
          end
        end
        return nil
      }
    end

    def get_rsinfo(index, prop)
      @cache_lock.synchronize {
        if @rs_map.has_key?(index)
          return @rs_map[index][prop]
        end
        return nil
      }
    end  

    def refresh_cache
      while true
        @cache_lock.synchronize {
          @condition.wait(@cache_lock, @refresh_interval_seconds)
          # Flush the cache completely to prevent it from growing indefinitly
          # @vs_map={}
          # @subvs_map={}
          # rs_map={}
          # load the maps
        }
      end
    end

end #class KempDevice

end #module