FROM php:7.4-fpm

RUN pecl install -o -f redis \
&&  rm -rf /tmp/pear \
&&  echo "extension=redis.so" > /usr/local/etc/php/conf.d/redis.ini \
&&  echo "session.save_handler = redis" >> /usr/local/etc/php/conf.d/redis.ini \
&&  echo "session.save_path = tcp://redis:6379" >> /usr/local/etc/php/conf.d/redis.ini