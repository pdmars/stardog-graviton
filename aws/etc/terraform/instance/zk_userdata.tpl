#!/bin/bash

set -e

date > /tmp/boottime

echo '${zk_conf}' > /usr/local/zookeeper-3.4.11/conf/zoo.cfg
echo ${index} > /var/zkdata/myid

localip=`curl http://169.254.169.254/latest/meta-data/local-ipv4`
num=`cat /var/zkdata/myid`

elb_name=`grep server.$num /usr/local/zookeeper-3.4.11/conf/zoo.cfg | sed 's/.*=//' | sed 's/:.*//'`

/usr/local/bin/stardog-wait-for-pgm 100 ping -c 1 $elb_name
ln -s /etc/sv/zkmon /etc/service/
${zk_health_wait}

${environment_variables}
echo '${environment_variables}' > /etc/zookeeper.env.sh

echo "$localip $elb_name" >> /etc/hosts
/usr/local/zookeeper-3.4.11/bin/zkServer.sh start

echo "Running the custom zk script..."
CUSTOM_SCRIPT=/tmp/customzk
echo '${custom_zk_script}' | /usr/bin/base64 -d > $CUSTOM_SCRIPT
chmod 755 $CUSTOM_SCRIPT
$CUSTOM_SCRIPT

echo "Done $?"


date >> /tmp/boottime
