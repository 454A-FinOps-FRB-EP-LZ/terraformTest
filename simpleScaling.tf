provider "aws" {
  region = "us-east-1"
}

# IAM Role for EC2 SSM access
resource "aws_iam_role" "ec2_ssm_role" {
  name = "ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Attach SSM and Fleet Manager permissions to the IAM role
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create an instance profile for the IAM role
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2-instance-profile"
  role = aws_iam_role.ec2_ssm_role.name

  lifecycle {
    create_before_destroy = true
  }
}

# VPC
resource "aws_vpc" "example" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "example-vpc"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Public subnets in two different Availability Zones
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"

  tags = {
    Name = "public-subnet-a"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1b"

  tags = {
    Name = "public-subnet-b"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.example.id

  tags = {
    Name = "example-igw"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.example.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-rt"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Associate the Route Table with the Public Subnets
resource "aws_route_table_association" "public_assoc_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route_table_association" "public_assoc_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id

  lifecycle {
    create_before_destroy = true
  }
}

# Security Group for Web Access
resource "aws_security_group" "web_sg" {
  vpc_id = aws_vpc.example.id

  ingress {
    from_port   = 1313
    to_port     = 1313
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Application Load Balancer (ALB)
resource "aws_lb" "web_lb" {
  name               = "web-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]

  tags = {
    Name = "web-lb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Target Group for ALB
resource "aws_lb_target_group" "web_tg" {
  name     = "web-tg"
  port     = 1313
  protocol = "HTTP"
  vpc_id   = aws_vpc.example.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    protocol            = "HTTP"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Listener for ALB (HTTP on port 80)
resource "aws_lb_listener" "web_lb_listener" {
  load_balancer_arn = aws_lb.web_lb.arn
  port              = "1313"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Launch Template for EC2 Instances
resource "aws_launch_template" "web_lc" {
  name_prefix           = "web-launch-configuration"
  image_id              = "ami-0ebfd941bbafe70c6"
  instance_type         = "t2.micro"
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  monitoring {
    enabled = true
  }

  # Attach the IAM Instance Profile to enable SSM Session Manager and Fleet Manager
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  # Add user data, base64 encoded by Terraform
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Install the SSM Agent
    sudo yum update -y
    sudo yum install -y amazon-ssm-agent

    # Install CloudWatch Agent
    sudo yum install -y amazon-cloudwatch-agent

    # Create CloudWatch Agent configuration file
    cat <<EOC > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
    {
        "metrics": {
        "namespace": "CWAgent",
        "metrics_collected": {
            "mem": {
            "measurement": [
                {"name": "mem_used_percent", "rename": "MemoryUtilization"}
            ],
            "metrics_collection_interval": 60
            }
        },
        "append_dimensions": {
            "AutoScalingGroupName": "$${aws:AutoScalingGroupName}",
            "InstanceId": "$${aws:InstanceId}"
        }
        }
    }
    EOC

    # set up to run APIs
    sudo yum install -y git python3 pip
    sudo pip3 install flask gunicorn psutil

    # start and enable the SSM Agent
    sudo systemctl start amazon-ssm-agent
    sudo systemctl enable amazon-ssm-agent

    # start CloudWatch Agent
    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

    # plug in API code here hi
    sudo chmod 777 /home/ec2-user
    cd /home/ec2-user
    git clone https://github.com/454A-FinOps-FRB-EP-LZ/RestAPIs.git
    cd RestAPIs
    sudo pip3 install -r requirements.txt
    sudo FLASK_APP=Routes.py flask run --host=0.0.0.0 --port=1313 &
    # sudo gunicorn --workers $(nproc) --bind 0.0.0.0:80 Routes:api &
  EOF
  )

  lifecycle {
    create_before_destroy = true
  }
}

# IAM perms for cloudwatch agent
resource "aws_iam_policy" "cloudwatch_agent_policy" {
  name   = "CloudWatchAgentServerPolicy"
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "cloudwatch:PutMetricData",
          "ec2:DescribeTags",
          "ec2:DescribeInstances"
        ],
        "Resource": "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent_policy_attach" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = aws_iam_policy.cloudwatch_agent_policy.arn
}

# Auto Scaling Group for EC2 Instances
resource "aws_autoscaling_group" "web_asg" {
  desired_capacity     = 2
  max_size             = 5
  min_size             = 2

  launch_template {
    id      = aws_launch_template.web_lc.id
    version = "$Latest"
  }
  
  vpc_zone_identifier     = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]
  health_check_grace_period = 300
  target_group_arns         = [aws_lb_target_group.web_tg.arn]

  tag {
    key                 = "Name"
    value               = "web-asg-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "web-server"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# CPU
# CPU scale policy up
resource "aws_autoscaling_policy" "scale_up" {
  name = "cpu-asg-scale-up"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = "2"
  cooldown = "300"
  policy_type = "SimpleScaling"
}

# CPU scale alarm up
resource "aws_cloudwatch_metric_alarm" "scale_up_alarm" {
  alarm_name = "cpu-asg-scale-up-alarm"
  alarm_description = "asg-scale-up-cpu-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = "10"
#   period = "120"
  statistic = "Average"
  threshold = "50" # create new instance when cpu >= 70
  dimensions = {
    "AutoScalingGroupName" = aws_autoscaling_group.web_asg.name
  }
  actions_enabled = true
  alarm_actions = [aws_autoscaling_policy.scale_up.arn]
}

# CPU scale policy down
resource "aws_autoscaling_policy" "scale_down" {
  name = "cpu-asg-scale-down"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = "-1"
  cooldown = "300"
  policy_type = "SimpleScaling"
}

# CPU scale alarm down
resource "aws_cloudwatch_metric_alarm" "scale_down_alarm" {
  alarm_name = "cpu-asg-scale-down-alarm"
  alarm_description = "asg-scale-down-cpu-alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "CPUUtilization"
  namespace = "AWS/EC2"
  period = "10"
#   period = "120"
  statistic = "Average"
  threshold = "30" # scale down <= 30
  dimensions = {
    "AutoScalingGroupName" = aws_autoscaling_group.web_asg.name
  }
  actions_enabled = true
  alarm_actions = [aws_autoscaling_policy.scale_down.arn]
}

# Memory
# Memory Scale-Up Policy
resource "aws_autoscaling_policy" "memory_scale_up" {
  name = "memory-asg-scale-up"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = "2"
  cooldown = "300"
  policy_type = "SimpleScaling"
}

# Memory Scale-Up Alarm
resource "aws_cloudwatch_metric_alarm" "memory_scale_up_alarm" {
  alarm_name = "memory-asg-scale-up-alarm"
  alarm_description = "asg-scale-up-memory-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "MemoryUtilization" # Assuming CloudWatch Agent publishes this custom metric
  namespace = "CWAgent" # Custom namespace defined in CloudWatch Agent config
#   period = "120"
  period = "10"
  statistic = "Average"
  threshold = "70" # Scale up when memory usage >= 70%
  dimensions = {
    "AutoScalingGroupName" = aws_autoscaling_group.web_asg.name
  }
  actions_enabled = true
  alarm_actions = [aws_autoscaling_policy.memory_scale_up.arn]
}

# Memory Scale-Down Policy
resource "aws_autoscaling_policy" "memory_scale_down" {
  name = "memory-asg-scale-down"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = "-1"
  cooldown = "300"
  policy_type = "SimpleScaling"
}

# Memory Scale-Down Alarm
resource "aws_cloudwatch_metric_alarm" "memory_scale_down_alarm" {
  alarm_name = "memory-asg-scale-down-alarm"
  alarm_description = "asg-scale-down-memory-alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods = "2"
  metric_name = "MemoryUtilization" # Custom metric for memory usage
  namespace = "CWAgent" # Custom namespace
#   period = "120"
  period = "10"
  statistic = "Average"
  threshold = "30" # Scale down when memory usage <= 30%
  dimensions = {
    "AutoScalingGroupName" = aws_autoscaling_group.web_asg.name
  }
  actions_enabled = true
  alarm_actions = [aws_autoscaling_policy.memory_scale_down.arn]
}

# Output the ALB DNS name
output "alb_dns_name" {
  value = aws_lb.web_lb.dns_name
}
