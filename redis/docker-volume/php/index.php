<?php

$redis = new Redis();

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

foreach ($sentinel as $value) {
    try {
        $redis->connect($value['host'], $value['port']);
        $redis->set('foo', 'bar');
        echo "連線成功 " . $value['host'] . "<br>目前 master：" . $value['role'] . "<br>";
    } catch (\Exception $e) {
        continue;
    }
}
