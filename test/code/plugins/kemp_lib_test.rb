require 'test/unit'
require 'rexml/document'
require_relative ENV['BASE_DIR'] + '/test/lib/plugins/kemp_lib'

class KempTest < KempRest::KempDevice
  private
  def access_get(command)
      # Load response samples
      stats_xml = File.read(File.join(File.dirname(__FILE__), "stats.xml"))
      getall_xml = File.read(File.join(File.dirname(__FILE__),'getall.xml'))
      listvs_xml = File.read(File.join(File.dirname(__FILE__),'listvs.xml'))
      vstotals_xml=File.read(File.join(File.dirname(__FILE__),'vstotals.xml'))
      licenseinfo_xml=File.read(File.join(File.dirname(__FILE__),'licenseinfo.xml'))

    case command
    when 'stats'
      result = REXML::Document.new(stats_xml) 
    when 'getall'
      result = REXML::Document.new(getall_xml)
    when 'licenseinfo'
      result=REXML::Document.new(licenseinfo_xml)
    when 'showhsm'
      result=REXML::Document.new(listvs_xml)
      when 'listvs'
      result=REXML::Document.new(listvs_xml)
    end
    result
  end
end

class KempLibtest < Test::Unit::TestCase
  class << self
    def startup
      @@perf_map = [
        {:object=>'Processor', :instance=>'_Total', :selector=>'CPU.total', :counters => [
            {:counter=>'% System Time', :value=>'System'},
            {:counter=>'% User Time',  :value=>'User'},
            {:counter=>'% Total Time',  :value=>'[% System Time]+[% User Time]'},
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
            {:counter=>'in bytes/sec', :value=>'inbytes'},
            {:counter=>'out bytes/sec', :value=>'outbytes'},
            {:counter=>'% bandwidth in', :value=>'in'},
            {:counter=>'% bandwidth out', :value=>'out'}
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
        {:object=>'VS', :instance=>'*.Index', :selector=>'Vs', :counters => [
          {:counter=>'Active Connections', :value=>'ActiveConns'},
          {:counter=>'Connections/sec', :value=>'ConnsPerSec'}
          ]
        },
        {:object=>'RS', :instance=>'*.RSIndex', :selector=>'Rs', :counters => [
          {:counter=>'Active Connections', :value=>'ActivConns'},
          {:counter=>'Connections/sec', :value=>'ConnsPerSec'}
          ]
        }
      ]
      @@device = KempTest.new('127.0.0.1', 'user', 'password', 1, 1)

      #puts @device.send(:access_get,'stats')
    end

    def shutdown
    end
  end


    def test_parse_counter
      assert(! @@device.nil?, 'Error device is not initialized')
      counter_hash = @@device.send(:access_get,'stats')
      counter_name='% System Time'
      instance='_Total'
      expected_value=119
      result=@@device.parse_counter(counter_hash, 'CPU.total', instance, counter_name, 'System')
      assert_equal(counter_name, result[instance]['CounterName'], "Returned CounterName is not #{counter_name} <> #{result[instance]['CounterName']}")
      assert_equal(expected_value, result[instance]['Value'], "Returned Counter Value is not #{expected_value} <> #{result[instance]['Value']}")

      #check for multiple instances :counters
      counter_name='Active Connections'
      instance='*.RSIndex'
      selector='Rs'
      value='ActivConns'
      result=@@device.parse_counter(counter_hash, selector, instance, counter_name, value)
      assert_equal(197,result.count, "Returned number of instances is wrong")
    end

    def test_device_info
      result = @@device.device_info()
      puts result
      assert_equal('SMv-INF-KEMP1a', result['ha1hostname'], "Mismatch in parsing device_info properties")
    end

    def test_vsrs_status
      result = @@device.vsrs_status()
      assert_equal(314, result.count, 'Wrong number of entried returned')
      assert_equal("3", result[0]['index'], 'Wrong parsing of entries')
    end

    def test_device_perf
      result = @@device.device_perf(@@perf_map)
      assert_equal(242, result.count, 'Wrong number of entried returned')
      assert_equal('KempLM-Processor', result[0]['ObjectName'], 'Wrong parsing of entries') 
    end
end
