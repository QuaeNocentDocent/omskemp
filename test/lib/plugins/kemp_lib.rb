module KempRest

require 'net/http'
require 'net/https'
require 'rexml/document'
require 'rexml/encoding'
require 'uri'
require 'logger'
require 'time'
require 'date'

require_relative 'oms_common'



class KempDevice

    attr_accessor :timeout
    attr_accessor :retries
    attr_accessor :wait_secs
    attr_accessor :username
    attr_accessor :password
    attr_accessor :name

    @@log =  Logger.new(STDERR) #nil
    @@log.formatter = proc do |severity, time, progname, msg|
        "#{time} #{severity} #{msg}\n"
    end


    def initialize(device_name, username, password, retries=3, wait_sec=2, timeout=30, refresh_interval_seconds=60)
      @timeout=timeout
      @retries=retries
      @wait_secs=wait_sec
      @name=device_name
      @username=username
      @password=password
      @vs_map={}
      @subvs_map={}
      @rs_map={}

      #let's leave some sync objects here but basically do nothing in this version
      @cache_lock = Mutex.new
      @refresh_interval_seconds = refresh_interval_seconds
      @condition = ConditionVariable.new
      @stop_cache=false
      #to be implemented in future versions
      #@thread = Thread.new(&method(:refresh_cache))

    end

  def destroy
      @stop_cache = true
      @thread.join
  end

  def parse_counter(counters_hash, selector, instance, counter_label, value)
  #returns instance and value if found
  #selector is a dotted list of path, the last one can be a *, in this case instance si the relative path starting from the previous node and value must be get of every instance

    #let's transletae from dotted to / notation, let's copy the string to avoid side effects on multiple calls
    t_instance=instance.sub('.','/')
    t_selector=selector.sub('.','/')
    t_value=value.sub('.','/')

    result={}
    counters_hash.each_element("/Response/Success/Data/#{t_selector}") { |el|
      case t_instance
      when /^[*]$/
          c_instance = el.name
      when /^[*]\//
          c_instance = el.get_text(t_instance.sub(/^[*][\/]/,'')).value
      else
          c_instance = t_instance
      end
      c_value = el.get_text(t_value).value.to_f #unless el.get_text(t_value).nil?
      result[c_instance] = {'CounterName'=>counter_label, 'Value'=>c_value}
    }

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

  def device_info ()
    #tbd. create a data structure with cvommands and props to make the info gathering flexible
    props=['dfltgw', 'hamode', 'havhid', 'hastyle','backupenable','backuphost','ha1hostname','hostname','ha2hostname','serialnumber','version']

    #for ha1hostname better a regexp
    @@log.debug {"device_info: getting data for #{@name}"}
    device_info = access_get('getall')
    results={}
    unless device_info.nil?
      props.each {|p| results[p]=device_info.get_text("/Response/Success/Data/#{p}").value}
    end
    #now get licesning info
    props=['uuid', 'LicensedUntil', 'SupportUntil', 'LicenseType','LicenseStatus','ActivationDate','ApplicaneModel','ApplianceModel']    
    @@log.debug {"device_info: getting license info for #{name}"}
    device_info = access_get('licenseinfo')

    unless device_info.nil?
      props.each {|p| results[p]=device_info.get_text("/Response/Success/Data/#{p}").value unless device_info.get_text("/Response/Success/Data/#{p}").nil?}
    end
    #some translation here for the AppicaneModel properties to correct a typo in Kemp interface
    if ! results['ApplicaneModel'].nil?
        results['ApplianceModel'] = results.delete('ApplicaneModel')
    end
    #cleanup and convert
    #nyi excpetion management during conversion    

    props.each {|p| results[p].gsub!(/(\\n|[^0-9A-Za-z :])/, '') unless results[p].nil?}
    ['ActivationDate','SupportUntil'].each {|p| results[p]=format_time(results[p]) unless results[p].nil?}
    results['LicensedUntil'] = results['LicensedUntil'] == 'unlimited' ? format_time('01-01-2099') : format_time(results['LicensedUntil'])
     
    #finally get if an HSM is installed
    props=['engine']
    @@log.debug {"device_info: getting HSM info for #{name}"}
    device_info = access_get('showhsm')
    unless device_info.nil?
      props.each {|p| results[p]=device_info.get_text("/Response/Success/Data/HSM/#{p}").value unless device_info.get_text("/Response/Success/Data/#{p}").nil?}
    end
    #some translation here for the AppicaneModel properties to correct a typo in Kemp interface
    if results['engine']
        results['hsmengine'] = results.delete('engine')
    end
    
    results
  end

  def vsrs_status()
    #return an array of hash
    # 'type': vs|rs|subvs
    # 'index':
    # 'parentindex': nil for vs
    # 'name'
    # 'parentname'
    # 'status'
    # 'address' 
    load_maps()
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


  def device_perf (counters_map)

    #open points
    #- objects naming, shall I try to use standard names (like "Processor") or make it clear it's a Kemp object? In LA we don't have much status right now, just the Computer/Host name can join the counter to other data sets
    #- we must set meaningful naming for VS and RS instances, this means getting all the VSs and RSs, this should be cached
    #we must return an array of objects with the following pseduo schema
    #{
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

    perf=access_get('stats')
    performance_points=[]
    unless perf.nil?      
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
    load_maps()

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
    def access_get (command)    
      #@@log.debug {"device_rest: getting data for #{name}"}

      uri=URI("https://#{@name}/access/#{command}")    
      req=Net::HTTP::Get.new(uri)
      req.basic_auth(@username, @password)
      http= Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl=true
      http.read_timeout=@timeout
      #more often than not Kemp devices use self signed certificates
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      result = nil
      retries=@retries
      begin
        response=http.request(req)
        response.decode_content = true
        result=REXML::Document.new(response.body) if response.code == '200'
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

    def load_maps()
      device_info = access_get('listvs')

      if device_info.nil?
          raise "Error getting VS list from #{@name}"
      end
      #now we must build a VS and subVS hash, this should be cached
      #right now let's implement a ctach all
        #device_info['Response']['Success']['Data']['VS'].each { |vs|    
        device_info.each_element('/Response/Success/Data/VS') { |vs|
          begin
            @vs_map[vs.get_text('Index').value]={
              :address =>(vs.get_text('VSAddress').value unless vs.get_text('VSAddress').nil?),
              :name => (vs.get_text('NickName').value unless vs.get_text('NickName').nil?) ,
              :status => vs.get_text('Status').value,
              :enable => vs.get_text('Enable').value
            }    
            if ! vs.elements['SubVS'].nil?
                vs.each_element('SubVS') {|sub|
                  @subvs_map[sub.get_text('VSIndex').value]={
                    :address =>vs.get_text('VSAddress').value,
                    :name => sub.get_text('Name').value,
                    :vsindex => vs.get_text('Index').value,
                    :status => sub.get_text('Status').value,
                    :enable =>  vs.get_text('Enable').value
                  }               
                }          
            end  
            if ! vs.elements['Rs'].nil?
                vs.each_element('Rs') {|r|
                  @rs_map[r.get_text('RsIndex').value]={
                    :address =>r.get_text('Addr').value,
                    :name => '',
                    :vsindex => r.get_text('VSIndex').value,
                    :status => r.get_text('Status').value,
                    :enable => vs.get_text('Enable').value
                  }               
                }          
            end      
          rescue Exception => e
            @@log.error {"load_maps: error populating VS and RS maps for #{vs.get_text('Index').value} #{e.message}"}
          end
        }
        #now remove from the vs_map the sub_vs
        @subvs_map.each { |key, value|
          if ! @vs_map[key].nil? then @vs_map.delete(key) end
        }
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
      while @stop_cache == false
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