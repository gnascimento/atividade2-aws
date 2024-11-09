# 1. VPC Principal
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "main-vpc"
  }
}

# 2. Sub-redes públicas para o Load Balancer
resource "aws_subnet" "alb_public_subnet_a" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
  tags = {
    Name = "alb-public-subnet-a"
  }
}

resource "aws_subnet" "alb_public_subnet_b" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1b"
  tags = {
    Name = "alb-public-subnet-b"
  }
}

# 3. Sub-redes privadas para instâncias EC2
resource "aws_subnet" "ecs_private_subnet_a" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "ecs-private-subnet-a"
  }
}

resource "aws_subnet" "ecs_private_subnet_b" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "us-east-1b"
  tags = {
    Name = "ecs-private-subnet-b"
  }
}

# 4. Gateway de Internet
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.main_vpc.id
  tags = {
    Name = "main-internet-gateway"
  }
}

# 5. Tabela de Rotas para Sub-redes Públicas
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }

  tags = {
    Name = "public-route-table"
  }
}

# Associação das Sub-redes Públicas à Tabela de Rotas Pública
resource "aws_route_table_association" "public_route_a" {
  subnet_id      = aws_subnet.alb_public_subnet_a.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public_route_b" {
  subnet_id      = aws_subnet.alb_public_subnet_b.id
  route_table_id = aws_route_table.public_route_table.id
}

# 6. NAT Gateway para acesso à internet para sub-redes privadas
resource "aws_eip" "nat_eip" {
  vpc = true
}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.alb_public_subnet_a.id
}

# 7. Tabela de Rotas para Sub-redes Privadas
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.main_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway.id
  }
}

# Associação das Sub-redes Privadas à Tabela de Rotas Privada
resource "aws_route_table_association" "private_route_a" {
  subnet_id      = aws_subnet.ecs_private_subnet_a.id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "private_route_b" {
  subnet_id      = aws_subnet.ecs_private_subnet_b.id
  route_table_id = aws_route_table.private_route_table.id
}

# 8. Cluster ECS
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "ecs-cluster"
}

# 9. Security Group para as Instâncias ECS
resource "aws_security_group" "ecs_security_group" {
  name        = "ecs-instance-sg"
  description = "Allow inbound traffic for ECS instances"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 10. Template de Lançamento para Instâncias EC2 do ECS
resource "aws_launch_template" "ecs_launch_template" {
  name_prefix   = "ecs-instance-template"
  instance_type = "t3.medium"
  image_id      = data.aws_ami.amzn2.id

  network_interfaces {
    security_groups = [aws_security_group.ecs_security_group.id]
  }

  user_data = base64encode(<<EOF
        #!/bin/bash
        echo ECS_CLUSTER=${aws_ecs_cluster.ecs_cluster.name} >> /etc/ecs/ecs.config
        EOF
  )

  metadata_options {
    http_endpoint               = "enabled"  # Habilita o serviço de metadados
    http_tokens                 = "optional" # Habilita IMDSv1 and IMDSv2
    http_put_response_hop_limit = 2          # Numero maximo de hops permitido para alcançar os metadados
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }
}

data "aws_ami" "amzn2" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*-x86_64-ebs"]
  }
}

# 11. Auto Scaling Group para instâncias ECS
resource "aws_autoscaling_group" "ecs_auto_scaling_group" {
  desired_capacity = 2
  max_size         = 3
  min_size         = 2
  launch_template {
    id      = aws_launch_template.ecs_launch_template.id
    version = "$Latest"
  }

  vpc_zone_identifier = [aws_subnet.ecs_private_subnet_a.id, aws_subnet.ecs_private_subnet_b.id]

  tag {
    key                 = "Name"
    value               = "ECS Instance"
    propagate_at_launch = true
  }
  target_group_arns = [aws_lb_target_group.app_target_group.arn]
}



# 12. Repositório ECR
resource "aws_ecr_repository" "app_container_repository" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE" # Permite substituir imagens com a mesma tag
}

# 13. Definição de Tarefa ECS usando imagem ECR
resource "aws_ecs_task_definition" "app_task_definition" {
  family                   = "app-task"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name        = "app-container",
      image       = "${aws_ecr_repository.app_container_repository.repository_url}:${var.image_tag}",
      cpu         = 256,
      memory      = 512,
      essential   = true,
      portMappings = [
        {
          containerPort = 80,
          hostPort      = 80
        }
      ],
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
        interval    = 30,
        timeout     = 5,
        retries     = 3,
        startPeriod = 60
      }
    }
  ])
}

# 14. Load Balancer da Aplicação em Sub-redes Públicas
resource "aws_lb" "application_load_balancer" {
  name               = "app-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_security_group.id]
  subnets            = [aws_subnet.alb_public_subnet_a.id, aws_subnet.alb_public_subnet_b.id]
}

resource "aws_lb_target_group" "app_target_group" {
  name     = "app-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main_vpc.id
  tags = {
    Name = "app_tg"
  }
  # Configuração do Health Check
  health_check {
    enabled             = true
    interval            = 60          # Intervalo entre verificações de saúde em segundos
    timeout             = 5           # Tempo limite para cada verificação de saúde em segundos
    healthy_threshold   = 2           # Número de verificações bem-sucedidas antes de marcar como saudável
    unhealthy_threshold = 2           # Número de falhas consecutivas antes de marcar como não saudável
    matcher             = "200"       # Código de status HTTP esperado para considerar saudável
    path                = "/"         # Caminho que o ALB usará para o health check
  }
}

resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.application_load_balancer.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_target_group.arn
  }
}

# 15. Serviço ECS
resource "aws_ecs_service" "app_ecs_service" {
  name            = "app-service"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.app_task_definition.arn
  desired_count   = 2

  load_balancer {
    target_group_arn = aws_lb_target_group.app_target_group.arn
    container_name   = "app-container"
    container_port   = 80
    #elb_name = aws_lb.application_load_balancer.name
  }

  depends_on = [aws_lb_listener.app_listener, aws_ecs_cluster_capacity_providers.ecs_cluster_capacity_provider_association]

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ecs_capacity_provider.name
    weight = 20 ### weight - (Optional) The relative percentage of the total number of launched tasks that should use the specified capacity provider. The weight value is taken into consideration after the base count of tasks has been satisfied. Defaults to 0
  }
}

resource "aws_ecs_cluster_capacity_providers" "ecs_cluster_capacity_provider_association" {
  cluster_name       = aws_ecs_cluster.ecs_cluster.name
  capacity_providers = [aws_ecs_capacity_provider.ecs_capacity_provider.name]
  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ecs_capacity_provider.name
    weight            = 20
    base              = 1
  }
}

resource "aws_ecs_capacity_provider" "ecs_capacity_provider" {
  name                = "app-capacity-prov"
  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs_auto_scaling_group.arn
    managed_scaling {
      maximum_scaling_step_size   = 1
      minimum_scaling_step_size   = 1
      status                      = "ENABLED"
      target_capacity             = 80 # Tenta manter o uso de 80% de CPU
    }
  }
}


# 16. Build e Push da Imagem Docker para o ECR
resource "null_resource" "docker_build_and_push" {
  depends_on = [aws_ecr_repository.app_container_repository]

  provisioner "local-exec" {
    command = <<EOT
      REPOSITORY_URI=${aws_ecr_repository.app_container_repository.repository_url}
      aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin $REPOSITORY_URI
      docker build --platform linux/amd64 -t ${var.repository_name}:${var.image_tag} .
      docker tag ${var.repository_name}:${var.image_tag} $REPOSITORY_URI:${var.image_tag}
      docker push $REPOSITORY_URI:${var.image_tag}
    EOT
  }
}


# 17. IAM Role para execução de tarefas ECS
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "ecs-task-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "ecs-task-execution-role"
  }
}

# Associação da política AmazonECSTaskExecutionRolePolicy à role de execução de tarefas
resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Associa role para as instancias ec2
resource "aws_iam_role" "ecs_instance_role" {
  name = "ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance_role_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs-instance-profile"
  role = aws_iam_role.ecs_instance_role.name
}
