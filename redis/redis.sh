#!/bin/bash

green="\033[1;32m";white="\033[1;0m";red="\033[1;31m";

echo "master IPAddress:"
master_ip=`docker inspect redis-master | grep "IP" | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"`
echo $master_ip;
echo "------------------------------"
echo "slave1 IPAddress:"
slave1_ip=`docker inspect redis-slave1 | grep "IP" | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"`
echo $slave1_ip;
echo "------------------------------"
echo "slave2 IPAddress:"
slave2_ip=`docker inspect redis-slave2 | grep "IP" | egrep -o "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"`
echo $slave2_ip;
echo "------------------------------"


echo "master:"
docker exec -it redis-master redis-cli info Replication | grep role
echo "slave1:"
docker exec -it redis-slave1 redis-cli info Replication | grep role
echo "slave2:"
docker exec -it redis-slave2 redis-cli info Replication | grep role

