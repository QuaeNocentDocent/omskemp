#!/bin/sh

#
# Easy download/install/onboard script for the OMSAgent for Linux Kemp Extension
#

CONF_PATH="/etc/opt/microsoft/omsagent/conf/omsagent.d"
PLUGIN_PATH="/opt/microsoft/omsagent/plugin"
GITHUB_SOURCE="https://raw.githubusercontent.com/QuaeNocentDocent/OMS-Agent-for-Linux/kemp"

wget "$GITHUB_SOURCE/source/code/plugins/filter_kemp.rb"
wget "$GITHUB_SOURCE/source/code/plugins/in_qnd_kemp_rest.rb"
wget "$GITHUB_SOURCE/source/code/plugins/kemp_lib.rb"
wget "https://raw.githubusercontent.com/fluent/fluent-plugin-rewrite-tag-filter/master/lib/fluent/plugin/out_rewrite_tag_filter.rb"
wget "$GITHUB_SOURCE/installer/conf/omsagent.d/kemp.conf"

# I must implement some sort of version control and probably I must not copy the configuration file
cp ./*.rb $PLUGIN_PATH
#cp ./kemp.conf $CONF_PATH
