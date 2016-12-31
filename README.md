#Kemp LoadMaster Extension for OMS

##Caveats

- **This is a preview version of the solution** please feel free to experiment and report feedback. Installing the solution will make no arm to your running environment, but will ingest data into your OMS workspace. The format of the data can be changed in future releases.


##Solution goal

This solution will collect status, asset and performance data from your [Kemp](www.kemptechnologies.com) Application Delivery (ex loadmaster) devices into your OMS Log Analytics workspace.
Optionally a custom solution can be imported to display key information and set predefined searches and alerts.

##Installation

The solution is a natural extension of the Linux OMS Agent, so first of all you need to install and onboard a linux machine with the [OMS agent](https://github.com/Microsoft/OMS-Agent-for-Linux)
Once the agent is properly configured the easiest way to configure the solution is to run the following command:

~~~
sudo wget https://raw.githubusercontent.com/QuaeNocentDocent/omskemp/master/installer/kemp-install.sh && sh kemp-install.sh
~~~

You can obviously check on github what the script does and repro the steps manually.

if you want you can install the OMS Solution

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FQuaeNocentDocent%2Fomskemp%2Fmaster%2Fcode%2Ftemplates%2Fkempsolution.json" target="_blank">
    <img src="http://azuredeploy.net/deploybutton.png"/>
</a>
<a href="http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2FQuaeNocentDocent%2Fomskemp%2Fmaster%2Fcode%2Ftemplates%2Fkempsolution.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

![SolutionOverview](docs/pictures/solution overview.png?raw=true)

##configuration

On your Kemp devices you must enable the REST interface and create a readonly user for the data collection.

After the files have been installed and you configured the devices, you need to copy edit the kemp.conf sample file to include your kemp devices address. You can have as many source tags as you want, every source tag contains all the devices that are accessible with the same credentials.
In the nodes attribute you must specify the fqnd or ip address of your devices following the syntax in the installed configuration file:

~~~
<source>
  type qnd_kemp_rest
  interval 50m  #we could use a much larger interval but alerts can only go back 60 minutes currently
  interval_perf 30s
  interval_status 5m
  nodes ["kempdev1","kempdev2"]  
  user_name 'user'
  user_password 'password'
  tag oms.qnd.kemprest
  log_level info
</source>
~~~

You must then copy the kemp.conf file to /etc/opt/omsagent/conf/omsagent.d/kemp.conf (sudo cp ./kemp.conf /etc/opt/omsagent/conf/omsagent.d)
Lastly, you must retart the OMS agent "sudo service omsagent restart" and the data will be ingested in your workspace.

Optionally you can configure your Kemp devices to send syslog data to OMS, in this case the solution will intercept the stream and create for your a specific log that will be easier to query.
By default the solution is listening for syslog record on port 25326/udp.

##Query the data
The solution will create the following data types:

- KempDevice_CL
- KempStatus_CL
- Native performance data points under the object name umbrella of KempLM-* (just type Type:Perf ObjectName=KempLM-*)

...more doc and samples to be added

##How to remove the solution

Currently the solution cannot be removed from UI, this is an ARM provider limitation that will be lifted in the future.
While the generic solution can be removed from the the Azure [portal](https://portal.azure.com) in the Log Analytics workspace balde, under solutions, the view cannot.
The easiest way to remove the entire solution today is to use [armclient](https://github.com/projectkudu/ARMClient):

~~~
armclient login
armclient delete "https://management.azure.com/subscriptions/{your subscription Id}/resourceGroups/{your resource group name}/providers/Microsoft.OperationsManagement/solutions/Kemp Application Delivery?api-version=2015-11-01-preview"
armclient delete "https://management.azure.com/subscriptions/{your subscription Id}/resourceGroups/{your resource group name}/providers/Microsoft.OperationalInsights/workspaces/{your workspace name}/views/Kemp Application Delivery?api-version=2015-11-01-preview"
~~~

You can get the {your subscription Id}, {your resource group name} and {your workspace name} from the Azure portal.

##Debug

...todo

##Support

This solution is open source under the GPL-2.0 licensing agreement. Is it is basically free, anyway support for deploying and/or configuring it is not free, you can contact my company by [email](mailto:info@progel.it)

If you find this solution useful and want to contribute to local community events, socials and charities you can donate

<a href="https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&amp;hosted_button_id=TYVKJP655BD9S"><img src="https://www.paypal.com/en_US/i/btn/btn_donate_LG.gif" /></a>

#Resources and links

https://docs.microsoft.com/en-us/azure/log-analytics/log-analytics-template-workspace-configuration

https://github.com/Microsoft/azure-docs/blob/master/articles/log-analytics/log-analytics-api-alerts.md

`Tags: kemp, oms, msoms, solution, example, walkthrough, #msoms`