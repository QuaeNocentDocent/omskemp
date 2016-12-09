#Kemp LoadMaster Extension for OMS

##Caveats

- **This is a preview version of the solution** please feel free to experiment and report feedback. Installing the solution will make no arm to your running environment, but will ingest data into your OMS workspace. The format of the data can bechanged in future releases.
- **This git repo is going to be moved** initially I thought it was a good idea to from from the mail OMS agent repo, but now I'm not sure this is a wise decision, since there are afew chances I'll able to submit a pull request to the main repo. Thus I'm going to create a dedicated repo for this solution.


##Solution goal

This solution will collect status, asset and performance data from your [Kemp](www.kemptechnologies.com) Application Delivery (ex loadmaster) devices into your OMS Log Analytics workspace.
Optionally a custom solution can be imported to display key information and set predefined searches and alerts.

##Installation

The solution is a natural extension of the Linux OMS Agent, so first of all you need to install and onboard a linux machine with the [OMS agent](https://github.com/Microsoft/OMS-Agent-for-Linux)
Once the agent is properly configured the easiest way to configure the solution is to run the following command:

~~~
sudo wget https://raw.githubusercontent.com/QuaeNocentDocent/OMS-Agent-for-Linux/kemp/installer/scripts/kemp-install.sh && sh kemp-install.sh
~~~

You can obviously check on github what the script does and repro the steps manually.

if you want you can install the OMS Solution

<a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FQuaeNocentDocent%2FOMS-Agent-for-Linux%2Fkemp%2Fsource%2Fcode%2Ftemplates%2Fkempsolution.json" target="_blank">
    <img src="http://azuredeploy.net/deploybutton.png"/>
</a>
<a href="http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2FQuaeNocentDocent%2FOMS-Agent-for-Linux%2Fkemp%2Fsource%2Fcode%2Ftemplates%2Fkempsolution.json" target="_blank">
    <img src="http://armviz.io/visualizebutton.png"/>
</a>

...insert picture here

##configuration

On your Kemp devices you must enable the REST interface and create a readonly user for the data collection.

After the files have been installed and you configured the devices, you need to edit /etc/opt/omsagent/conf/omsagent.d/kemp.conf to include your kemp devices address. You cna have as many source tags as you want, every source tag contains all the devices that are accessible with the same credentials. In the nodes attribute you must specify the fqnd or ip address of your devices following the syntax in the installed configuration file:

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

Lastly, you must retart the OMS agent "sudo service omsagent restart" and the data will be ingested in your workspace.

Optionally you can configure your Kemp devices to send syslog data to OMS, in this case the solution will intercept the stream and create for your a specific log that will be easier to query.
By default the solution is listening for syslog record on port 25326/udp.

##Query the data
The solution will create the following data types:

- KempDevice_CL
- KempStatus_CL
- Native performance data points under the object name umbrella of KempLM-* (just type Type:Perf ObjectName=KempLM-*)

...more doc and samples to be added

##Debug

...todo

##Support

This solution is open source under the GPL-2.0 licensing agreement. Is it is basically free, anyway support for deploying and/or configuring it is not free, you can contact my company by [email](mailto:info@progel.it)

If you find this solution useful and want to contribute to local community events, socials and charities you can ...

<form action="https://www.paypal.com/cgi-bin/webscr" method="post" target="_top">
<input type="hidden" name="cmd" value="_s-xclick">
<input type="hidden" name="encrypted" value="-----BEGIN PKCS7-----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-----END PKCS7-----">
<input type="image" src="https://www.paypalobjects.com/it_IT/IT/i/btn/btn_donateCC_LG.gif" border="0" name="submit" alt="PayPal è il metodo rapido e sicuro per pagare e farsi pagare online.">
<img alt="" border="0" src="https://www.paypalobjects.com/it_IT/i/scr/pixel.gif" width="1" height="1">
</form>


#Resources and links

https://docs.microsoft.com/en-us/azure/log-analytics/log-analytics-template-workspace-configuration

https://github.com/Microsoft/azure-docs/blob/master/articles/log-analytics/log-analytics-api-alerts.md

`Tags: kemp, oms, msoms, solution, example, walkthrough, #msoms`