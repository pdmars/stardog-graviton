data "template_file" "stardog_zk_server" {
  count = "${var.zookeeper_size}"
  template = "$${host}:2181"
  vars {
    host = "${element(aws_elb.zookeeper.*.dns_name, count.index)}"
  }
}

data "template_file" "stardog_properties" {
  template = "${var.custom_stardog_properties}\n${file("stardog.properties.tpl")}"
  vars {
    zk_servers = "${join(",", data.template_file.stardog_zk_server.*.rendered)}"
    custom_data = "${var.custom_properties_data}"
  }
}

data "template_file" "stardog_userdata" {
  template = "${file("stardog_userdata.tpl")}"
  vars {
    custom_script = "${file(var.custom_script)}"
    stardog_conf = "${data.template_file.stardog_properties.rendered}"
    custom_log4j_data = "${var.custom_log4j_data}"
    deployment_name = "${var.deployment_name}"
    zk_servers = "${join(",", data.template_file.stardog_zk_server.*.rendered)}"
    environment_variables = "${var.environment_variables}"
    server_opts = "${var.stardog_start_opts}"
  }
}

resource "aws_autoscaling_group" "stardog" {
  count = "${var.stardog_size}"
  vpc_zone_identifier = ["${element(aws_subnet.stardog.*.id, count.index % length(aws_subnet.stardog.*.id))}"]
  name = "${var.deployment_name}sdasg${count.index}"
  max_size = "1"
  min_size = "1"
  desired_capacity = "1"
  launch_configuration = "${aws_launch_configuration.stardog.name}"
  target_group_arns = ["${aws_alb_target_group.stardog_alb_default_target_group.arn}", "${aws_alb_target_group.stardog_alb_default_target_group_internal.arn}"]
  health_check_grace_period = "${var.sd_health_grace_period}"
  health_check_type = "EC2"

  tag {
    key = "StardogVirtualAppliance"
    value = "${var.deployment_name}"
    propagate_at_launch = true
  }
  tag {
    key = "Name"
    value = "StardogNode"
    propagate_at_launch = true
  }
}

resource "aws_launch_configuration" "stardog" {
  name_prefix = "${var.deployment_name}sdlc"
  image_id = "${var.baseami}"
  instance_type = "${var.stardog_instance_type}"
  user_data = "${data.template_file.stardog_userdata.rendered}"
  key_name = "${var.aws_key_name}"
  security_groups = ["${aws_security_group.stardog.id}"]
  iam_instance_profile = "${aws_iam_instance_profile.stardog.id}"
  associate_public_ip_address = true

  root_block_device {
    volume_type = "${var.root_volume_type}"
    volume_size = "${var.root_volume_size}"
    iops = "${var.root_volume_type == "io1" ? var.root_volume_iops : 0}"
    delete_on_termination = "true"
  }
}

resource "aws_iam_instance_profile" "stardog" {
  name = "${var.deployment_name}test_profile"
  role = "${aws_iam_role.stardog.name}"
}

resource "aws_iam_role" "stardog" {
  name = "${var.deployment_name}role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "stardog" {
  name = "${var.deployment_name}test_policy"
  role = "${aws_iam_role.stardog.id}"
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
              "ec2:Describe*",
              "ec2:Attach*"
            ],
            "Effect": "Allow",
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": "autoscaling:*",
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
              "s3:List*",
              "s3:Get*"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

resource "aws_security_group" "stardog" {
  name = "${var.deployment_name}sdsg"
  description = "Allow stardog traffic"
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name = "stardog security group"
    Version = "${var.version}"
    StardogVirtualAppliance = "${var.deployment_name}"
  }

  # allow ssh from anywhere
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["${var.internal_network}"]
  }

  # stardog port
  ingress {
    from_port = 5821
    to_port = 5821
    protocol = "tcp"
    cidr_blocks = ["${var.internal_network}"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_security_group" "stardoglb" {
  name = "${var.deployment_name}sdlbsg"
  description = "Allow stardog traffic"
  vpc_id = "${aws_vpc.main.id}"

  tags {
    Name = "stardog security group"
    Version = "${var.version}"
    StardogVirtualAppliance = "${var.deployment_name}"
  }

  # allow ssh from anywhere
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # stardog port
  ingress {
    from_port = 5821
    to_port = 5821
    protocol = "tcp"
    cidr_blocks = ["${var.http_subnet}"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_subnet" "stardog" {
  count = "${length(data.aws_availability_zones.available.names)}"
  vpc_id = "${aws_vpc.main.id}"
  cidr_block = "${format("10.0.%d.0/24", count.index + 100)}"
  availability_zone = "${element(data.aws_availability_zones.available.names, count.index)}"

  tags {
    StardogVirtualAppliance = "${var.deployment_name}"
  }
}

resource "aws_alb" "stardog_alb" {
  name = "${var.deployment_name}sdalb"
  subnets = ["${aws_subnet.stardog.*.id}"]
  security_groups = ["${aws_security_group.stardoglb.id}"]
  idle_timeout = "${var.elb_idle_timeout}"
  internal = false
  ip_address_type = "ipv4"

  tags {
    StardogGraviton = "${var.deployment_name}"
  }
}

resource "aws_alb_listener" "stardog_alb_listener" {
  load_balancer_arn = "${aws_alb.stardog_alb.arn}"
  port = 5821
  protocol = "${var.external_protocol}"

  default_action {
    target_group_arn = "${aws_alb_target_group.stardog_alb_default_target_group.arn}"
    type = "forward"
  }
}

resource "aws_alb_listener_rule" "stardog_listener_transaction_rule" {
  listener_arn = "${aws_alb_listener.stardog_alb_listener.arn}"
  priority = 100

  action {
    type = "forward"
    target_group_arn = "${aws_alb_target_group.stardog_alb_transaction_target_group.id}"
  }

  condition {
    field = "path-pattern"
    values = ["/*/transaction/*"]
  }
}

resource "aws_alb_target_group" "stardog_alb_transaction_target_group" {
  name = "${var.deployment_name}-sd-transaction-tg"
  port = 5821
  protocol = "${var.external_protocol}"
  vpc_id = "${aws_vpc.main.id}"
  target_type = "instance"

  health_check {
    healthy_threshold = "${var.sd_healthy_threshold}"
    unhealthy_threshold = "${var.sd_unhealthy_threshold}"
    timeout = "${var.sd_health_timeout}"
    interval = "${var.sd_health_interval}"
    path = "/admin/cluster/coordinator"
    port = 5821
  }

  tags {
    StardogGraviton = "${var.deployment_name}"
  }
}

resource "aws_alb_target_group" "stardog_alb_default_target_group" {
  name = "${var.deployment_name}-sd-default-tg"
  port = 5821
  protocol = "${var.external_protocol}"
  vpc_id = "${aws_vpc.main.id}"
  target_type = "instance"

  health_check {
    healthy_threshold = "${var.sd_healthy_threshold}"
    unhealthy_threshold = "${var.sd_unhealthy_threshold}"
    timeout = "${var.sd_health_timeout}"
    interval = "${var.sd_health_interval}"
    path = "/admin/healthcheck"
    port = 5821
  }

  tags {
    StardogGraviton = "${var.deployment_name}"
  }
}

resource "aws_alb" "stardog_alb_internal" {
  name = "${var.deployment_name}sdialb"
  subnets = ["${aws_subnet.stardog.*.id}"]
  security_groups = ["${aws_security_group.stardog.id}"]
  idle_timeout = "${var.elb_idle_timeout}"
  internal = true
  ip_address_type = "ipv4"

  tags {
    StardogGraviton = "${var.deployment_name}"
  }
}

resource "aws_alb_listener" "stardog_alb_listener_internal" {
  load_balancer_arn = "${aws_alb.stardog_alb_internal.arn}"
  port = 5821
  protocol = "${var.external_protocol}"

  default_action {
    target_group_arn = "${aws_alb_target_group.stardog_alb_default_target_group_internal.arn}"
    type = "forward"
  }
}

resource "aws_alb_listener_rule" "stardog_listener_transaction_rule_internal" {
  listener_arn = "${aws_alb_listener.stardog_alb_listener_internal.arn}"
  priority = 100

  action {
    type = "forward"
    target_group_arn = "${aws_alb_target_group.stardog_alb_transaction_target_group_internal.id}"
  }

  condition {
    field = "path-pattern"
    values = ["/*/transaction/*"]
  }
}

resource "aws_alb_target_group" "stardog_alb_transaction_target_group_internal" {
  name = "${var.deployment_name}-sdi-transaction-tg"
  port = 5821
  protocol = "${var.external_protocol}"
  vpc_id = "${aws_vpc.main.id}"
  target_type = "instance"

  stickiness {
    type = "lb_cookie"
    cookie_duration = 1800
    enabled = true
  }

  health_check {
    healthy_threshold = "${var.sd_internal_healthy_threshold}"
    unhealthy_threshold = "${var.sd_internal_unhealthy_threshold}"
    timeout = "${var.sd_internal_health_timeout}"
    interval = "${var.sd_internal_health_interval}"
    path = "/admin/cluster/coordinator"
    port = 5821
  }

  tags {
    StardogGraviton = "${var.deployment_name}"
  }
}

resource "aws_alb_target_group" "stardog_alb_default_target_group_internal" {
  name = "${var.deployment_name}-sdi-default-tg"
  port = 5821
  protocol = "${var.external_protocol}"
  vpc_id = "${aws_vpc.main.id}"
  target_type = "instance"

  stickiness {
    type = "lb_cookie"
    cookie_duration = 1800
    enabled = true
  }

  health_check {
    healthy_threshold = "${var.sd_internal_healthy_threshold}"
    unhealthy_threshold = "${var.sd_internal_unhealthy_threshold}"
    timeout = "${var.sd_internal_health_timeout}"
    interval = "${var.sd_internal_health_interval}"
    path = "/admin/healthcheck"
    port = 5821
  }

  tags {
    StardogGraviton = "${var.deployment_name}"
  }
}

