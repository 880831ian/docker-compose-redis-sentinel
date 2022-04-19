## 什麼是 Redis 哨兵模式 (Sentinel) ?

有關 Redis 之前有寫一篇 [Redis 的介紹文](https://pin-yi.me/redis/)，有興趣可以去看看！

Redis 提供非常實用的功能來讓我們實現多機的 in-memory 資料庫：
*  主從複製模式 (Master-Slave Replication)
* 哨兵模式 (Sentinel)
*  叢集模式 (Cluster)

<br>

我們這邊主要介紹哨兵模式 (Sentinel)，但主要也是由主從複製模式 (Master-Slave Replication) 修改而來：

哨兵模式就是用來監視 Redis 系統，哨兵會監控 Master 是否正常運作。如果遇到 Master 出現故障或是離線時，哨兵之間會開始判斷，直到我們所設定需達到的判斷數量後，哨兵會將其所屬的 Slave 變成 Master，並再將其他的 Slave 指向新的 Master。

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/sentinal.png)


<br>

### 監控

哨兵會和要監控的 Master 建立兩條連接，`Cmd` 和 `Pub/Sub`：

* Cmd 是哨兵用來定期向 Master 發送 `Info` 命令以取得 Master 的訊息，訊息中會包含 Master 有哪些 Slave。當與 Master 獲得 Slave 訊息後，哨兵也會和 Slave 建立連接。
* 哨兵也會定期透過 `Cmd` 向 Master、Slave 和其他哨兵發送 `Ping` 指令來檢查是否存在，確認節點狀態等。
* `Pub/Sub` 讓哨兵可以透過訂閱 Master 和 Slave 的 `__Sentinel__:hello` 這個頻道來和其他哨兵定期的進行資訊交換。

<br>

### 主觀下線 (SDOWN)

主觀下線是指單個哨兵認為 Master 已經停止服務了，有可能是網路不通或是接收不到訂閱等，而哨兵的判斷是依據傳送 Ping 指令之後一定時間內是否收到回覆或是錯誤訊息，如果有哨兵就會主觀認為這個 Master 已經下線停止服務了。

<br>

### 客觀下線 (ODOWN)

客觀下線是指由多個哨兵對同一個 Master 各自進行主觀下線的判斷後，再綜合所有哨兵的判斷。若是認為主觀下線的哨兵到達我們所配置的數量後，即為客觀下線。

<br>

### 故障轉移 (Failover)

當 Master 已經被標記為客觀下線時，起初發現 Master 下線的哨兵會發起一個選舉 (採用的是 Raft 演算法)，並要求其他哨兵選他做為領頭哨兵，領頭哨兵會負責進行故障的恢復。當選的標準是要有超過一半的哨兵同意，所以哨兵的數量建議設定成奇數個。

此時若有多個哨兵同時參選領頭哨兵，則有可能會發生一輪後沒有產生勝選者，則所有的哨兵會再等隨機一個時間再次發起參選的請求，進行下一輪的選舉，一直到選出領頭為止。所以若哨兵數量為偶數就很有可能一直無法選出領頭哨兵。

<br>

選出領頭哨兵後，領頭哨兵會開始從下線的 Master 所屬 Slave 中跳選出一個來變成新的 Master，挑選的依據如下：
1. 所有在線的 Slave 擁有最高優先權的，優先權可以透過 slave-priority 來做設定。
2. 如果有多個同為最高優先權的 Slave，則會選擇複製最完整的。
3. 若還是有多個 Slave 皆符合上述條件，則選擇 id 最小的。

<br>

接著領頭哨兵會將舊的 Master 更新成新的 Master 的 Slave ，讓其恢復服務後以 Slave 的身份繼續運作。

<br>

## 用 Docker 實作 Redis 哨兵模式

本文章是使用 Docker 來實作 Redis 的哨兵模式，建議可以先觀看 [Redis 的哨兵模式介紹](https://pin-yi.me/redis-sentinel-docker/) 文章來簡單學習 Redis 的哨兵模式。

版本資訊
* macOS：11.6
* Docker：Docker version 20.10.12, build e91ed57
* Nginx：1.20
* PHP：7.4-fpm
* Redis：latest

<br>

### 檔案結構

```
.
├── Docker-compose.yaml
├── docker-volume
│   ├── log
│   │   └── nginx
│   │       ├── access.log
│   │       └── error.log
│   ├── nginx
│   │   └── nginx.conf
│   ├── php
│   │   └── index.php
│   ├── redis-master
│   ├── redis-slave1
│   └── redis-slave2
├── redis.sh
├── php
│   └── Dockerfile
└── sentinel
    ├── Docker-compose.yaml
    ├── sentinel1.conf
    ├── sentinel2.conf
    └── sentinel3.conf
```

<br>

這是主要的結構，簡單說明一下：

* Docker-compose.yaml：會放置要產生的 Nginx、PHP、redis-master、redis-slave1、redis-slave2 容器設定檔。
*  docker-volume：是我們要掛載進去到容器內的檔案，包含像是 nginx.conf 或是 log/nginx 以及 redis 記憶體儲存內容。
*  redis.sh：是我另外多寫的腳本，可以在最後方面我們測試 Redis sentinel 是否成功。
*  php/Dokcerfile：因為在 php 要使用 redis 需要多安裝一些設定，所以用 Dockerfile 另外寫 PHP 的映像檔。
*  sentinel/Docker-compose.yaml：會放置要產生的 sentinel1、sentinel2、sentinel3 的容器設定檔。
*  sentinel(1、2、3).conf：哨兵的設定檔。

<br>

那我們就依照安裝的設定開始說明：

### Docker-compose.yaml

```yml
version: '3.8'

services:
  nginx:
    image: nginx:1.20
    container_name: nginx
    ports:
      - "8888:80"
    volumes:
      - ./docker-volume/nginx/:/etc/nginx/conf.d/
      - ./docker-volume/log/nginx/:/var/log/nginx/

  php:
    build: ./php
    container_name: php
    expose:
      - 9000
    volumes:
      - ./docker-volume/php/:/var/www/html

  redis-master:
    image: redis
    container_name: redis-master
    volumes:
      - ./docker-volume/redis-master/:/data
    ports:
      - 6379:6379

  redis-slave1:
    image: redis
    container_name: redis-slave1
    volumes:
      - ./docker-volume/redis-slave1/:/data
    ports:
      - 6380:6379
    command: redis-server --slaveof redis-master 6379
    depends_on:
      - redis-master

  redis-slave2:
    image: redis
    container_name: redis-slave2
    volumes:
      - ./docker-volume/redis-slave2/:/data
    ports:
      - 6381:6379
    command: redis-server --slaveof redis-master 6379
    depends_on:
      - redis-master
      - redis-slave1
```
詳細的 Docker 設定說明，可以參考 [Docker 介紹](https://pin-yi.me/docker) 內有詳細設定說明。比較特別的地方是：

 redis-(master、slave1、slave2)
 * volumes：將 redis 的資料掛載到 docker-volume/redis-(master、slave1、slave2)。
 * command：使用 redis-server 啟動，並且將該服務器轉變成指定服務器的從屬服務器 (slave server)。

<br>

### docker-volume/nginx/nginx.conf

```conf
server {
  listen 80;
  server_name default_server;
  return 404;
}

server {
  listen 80;
  server_name test.com;
  index index.php index.html;

  error_log  /var/log/nginx/error.log  warn;
  access_log /var/log/nginx/access.log;
  root /var/www/html;

  location / {
    try_files $uri $uri/ /index.php?$query_string;
  }

  location ~ \.php$ {
      fastcgi_pass php:9000;
      fastcgi_index index.php;
      include fastcgi_params;
      fastcgi_param SCRIPT_FILENAME /var/www/html$fastcgi_script_name;
  }
}
```
Nginx 設定檔案。

<br>

### php/Dockerfile

```Dockerfile
FROM php:7.4-fpm

RUN pecl install -o -f redis \
&&  rm -rf /tmp/pear \
&&  echo "extension=redis.so" > /usr/local/etc/php/conf.d/redis.ini \
&&  echo "session.save_handler = redis" >> /usr/local/etc/php/conf.d/redis.ini \
&&  echo "session.save_path = tcp://redis:6379" >> /usr/local/etc/php/conf.d/redis.ini
```
因為 PHP 要使用 Redis，會需要安裝一些套件，所以我們將 PHP 分開來，使用 Dockerfile 來設定映像檔。

<br>

### sentinel/sentine.conf

因為 sentine 內容都基本上相同，所以舉一個來說明：

```conf
port 26379

#設定要監控的 Master，最後的 2 代表判定客觀下線所需的哨兵數
sentinel monitor mymaster 192.168.176.4 6379 2

#哨兵 Ping 不到 Master 超過此毫秒數會認定主觀下線
sentinel down-after-milliseconds mymaster 5000

#failover 超過次毫秒數即代表 failover 失敗
sentinel failover-timeout mymaster 180000
```
要設定指定的 Port sentine1 是 26379、sentine2 是 26380、sentine3 是 26381。接下來要設定要監控的 Master，最後的數字代表我們前面有提到客觀下線需要達到的哨兵數。以及主觀下線的時間跟 failover 超過的時間。

<br>

### sentinel/Docker-compose.yaml

```yml
version: '3.8'

services:
  sentinel1:
    image: redis
    container_name: redis-sentinel-1
    ports:
      - 26379:26379
    command: redis-sentinel /usr/local/etc/redis/sentinel.conf
    volumes:
      - ./sentinel1.conf:/usr/local/etc/redis/sentinel.conf

  sentinel2:
    image: redis
    container_name: redis-sentinel-2
    ports:
      - 26380:26379
    command: redis-sentinel /usr/local/etc/redis/sentinel.conf
    volumes:
      - ./sentinel2.conf:/usr/local/etc/redis/sentinel.conf

  sentinel3:
    image: redis
    container_name: redis-sentinel-3
    ports:
      - 26381:26379
    command: redis-sentinel /usr/local/etc/redis/sentinel.conf
    volumes:
      - ./sentinel3.conf:/usr/local/etc/redis/sentinel.conf

networks:
  default:
    external:
      name: redis_default
```

<br>

### docker-volume/php/index.php

```php
<?php

$redis = new Redis();

$sentinel = array(
    array(
        'host' => '192.168.176.4',
        'port' => 6379,
        'role' => 'master',
    ),
    array(
        'host' => '192.168.176.5',
        'port' => 6379,
        'role' => 'slave1',
    ),
    array(
        'host' => '192.168.176.6',
        'port' => 6379,
        'role' => 'slave2',
    ),

);

foreach ($sentinel as $value) {
    try {
        $redis->connect($value['host'], $value['port']);
        $redis->set('foo', 'bar');
        echo "連線成功 " . $value['host'] . "<br>目前 master：" . $value['role'] . "<br>";
    } catch (\Exception $e) {
        continue;
    }
}
```
為了要讓 PHP 可以知道目前的 Master 是哪一個服務器，所以寫了一個 try...catch 來做判斷，並且把3個服務內容都放到陣列中，後續再測試中會再說明。

<br>

### redis.sh

```sh
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
```
這個是我自己所寫的腳本，再等等測試時，可以詳細知道目前服務的角色轉移狀況。

<br>

## 測試

我們先用 docker-compose up 來啟動 Docker-compose.yaml ，接著下 sh redis.sh 指令來查看各服務的 IP 位置以及目前角色：

<br>


![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/docker-compose-up-1.png)

<br>


![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/redis-sh-1.png)

<br>

接下來先修改 docker-volume/php/index.php 

```php
$sentinel = array(
    array(
        'host' => '192.168.208.4',
        'port' => 6379,
        'role' => 'master',
    ),
    array(
        'host' => '192.168.208.5',
        'port' => 6379,
        'role' => 'slave1',
    ),
    array(
        'host' => '192.168.208.6',
        'port' => 6379,
        'role' => 'slave2',
    ),

);
```
將各自的 IP 帶入測試的網站中。

<br>

可以瀏覽 `test.com:8888` 是否有正常抓到 redis 的 master

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/php-1.png)

<br>

再來修改 sentinel 內的 sentinel(1、2、3).conf 檔案

```conf
port 26379

#設定要監控的 Master，最後的 2 代表判定客觀下線所需的哨兵數
sentinel monitor mymaster 192.168.208.4 6379 2

#哨兵 Ping 不到 Master 超過此毫秒數會認定主觀下線
sentinel down-after-milliseconds mymaster 5000

#failover 超過次毫秒數即代表 failover 失敗
sentinel failover-timeout mymaster 180000
```
將要監控的 Master IP 帶入 sentinel monitor mymaster。

<br>

再啟動 sentinel/Docker-compose.yaml

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/docker-compose-up-2.png)

<br>

接下來我們來模擬假設 Master 服務中斷後，sentinel 會發生什麼事情：

```sh
$ docker stop redis-master
```

<br>

下完指令後，再使用 `sh redis.sh` 來看看目前的 role 狀態：

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/redis-sh-2.png)

發現已經抓不到 master IP 以及他的角色。

<br>

等待一下子後，重新下 `sh redis.sh` 來看目前的 role 狀態：

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/redis-sh-3.png)

就會發現已經將 master 轉移到原 slave1。

<br>

那我們來看一下 sentinel 在背後做了哪些事情：

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/sentinal-1.png)

可以看到三個哨兵都認為 master 為 主觀下線 (sdown)，這時 sentinel-2 就認定為 客觀下線 (odown)，並發起投票要求成為領頭哨兵。

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/sentinal-2.png)

我們可以看到 Sentinel2 和 Sentinel3 都投給 Sentinel2，所以最後 Sentinel2 當選。

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/sentinal-3.png)

接著 sentinel2 選出 redis-slave1 (192.168.208.5:6379) 作為 Master ，並且使用 `failover-state-send-slaveof-noone` 來將 redis-slave1 解除 Slave 狀態變成獨立的 master，隨後將 redis-slave1 升成 master。

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/sentinal-4.png)

設定完新的 Master 後，Sentinel2 讓原本的 Master 轉為 Slave，並且讓 redis-slave2(192.168.208.6:6379) 指向新的 Master。最後 Sentinel1 和 Sentinel3 開始從 Sentinel2 取得設定然後更新自己的設定，至此整個故障轉移就完成了。

<br>

最後我們來看一下我們用 PHP 連線的測試：

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/php-2.png)


就會發現，已經 slave1 變成現在的 master。

<br>

那我們最後把原本的 master 恢復，看看會發生什麼事情：

<br>

![圖片](https://raw.githubusercontent.com/880831ian/redis-sentinel-docker/master/images/php-3.png)


會發現因為該啟動 master，所以他還認為他是 master，但過一下下，在查看就正常顯示 slave1 為 master，舊的 master 就變成 slave。

<br>

## 參考資料

[Redis (六) - 主從複製、哨兵與叢集模式](https://blog.tienyulin.com/redis-master-slave-replication-sentinel-cluster/)