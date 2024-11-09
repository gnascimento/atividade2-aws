# Usar a última versão do Ubuntu como base
FROM ubuntu:latest

# Definir frontend não interativo para evitar prompts durante a instalação
ENV DEBIAN_FRONTEND=noninteractive

# Atualizar e instalar Apache, PHP, e curl
RUN apt-get update && \
    apt-get install -y apache2 php libapache2-mod-php curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Habilitar o módulo de reescrita do Apache
RUN a2enmod rewrite

# Definir o diretório de trabalho
WORKDIR /var/www/html

# Criar o arquivo index.php que exibe o nome da instância
RUN echo "<?php \
    \$instance_name = @file_get_contents('http://169.254.169.254/latest/meta-data/instance-id'); \
    echo 'Hello from Instance ID: ' . \$instance_name; \
?>" > index.php

# Remover o arquivo padrão index.html do Apache
RUN rm -f /var/www/html/index.html

# Expor a porta 80 para acesso ao Apache
EXPOSE 80

# Comando para iniciar o Apache em primeiro plano
CMD ["apache2ctl", "-D", "FOREGROUND"]
