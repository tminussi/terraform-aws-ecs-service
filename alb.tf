data "aws_vpc" "selected" {
  count = "${var.enable_alb ? 1 : 0}"
  id = "${var.vpc_id}"
}

resource "aws_security_group" "security_group_alb" {
  // Only enable if LB is required
  count = "${var.enable_alb ? 1 : 0}"

  name_prefix = "${var.environment}-${var.service_name}"
  vpc_id      = "${var.vpc_id}"

  # allow all incoming traffic
  ingress = {
    from_port   = "${var.alb_port}"
    to_port     = "${var.alb_port}"
    protocol    = "tcp"
    cidr_blocks = ["${var.internal_alb ? data.aws_vpc.selected.cidr_block : "0.0.0.0/0"}"]
  }

  # allow all outgoing traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["${data.aws_vpc.selected.cidr_block}"]
  }

  tags = "${merge(map("Name", format("%s", "${var.environment}-${var.service_name}")),
            map("Environment", format("%s", var.environment)),
            map("Project", format("%s", var.project)),
            map("Application", format("%s", var.service_name)),
            var.tags)}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_alb" "alb" {
  // Only enable if LB is required
  count = "${var.enable_alb ? 1 : 0}"

  internal        = "${var.internal_alb}"
  security_groups = ["${aws_security_group.security_group_alb.id}"]
  subnets         = ["${split(",", var.subnet_ids)}"]

  idle_timeout = "${var.alb_timeout}"

  enable_deletion_protection = false

  tags = "${merge(map("Name", format("%s", "${var.environment}-${var.service_name}")),
            map("Environment", format("%s", var.environment)),
            map("Project", format("%s", var.project)),
            map("Application", format("%s", var.service_name)),
            var.tags)}"
}

resource "aws_alb_target_group" "target_group" {
  count = "${var.enable_alb || var.enable_load_balanced ? 1 : 0}"

  port     = "${var.container_port}"
  protocol = "${var.container_ssl_enabled ? "HTTPS" : "HTTP" }"
  vpc_id   = "${var.vpc_id}"

  health_check = ["${merge(
    map("protocol", format("%s", var.container_ssl_enabled ? "HTTPS" : "HTTP")),
    map("path", "/"),
    map("matcher", format("%s", var.health_check_matcher)),
    map("interval", format("%s", var.health_check_interval)),
    var.health_check
  )}"]

  lifecycle {
    create_before_destroy = true
  }

  # ALB id is added as tag to ensure the LB exists before creating the service
  tags = "${merge(map("Name", format("%s", "${var.environment}-${var.service_name}")),
            map("Environment", format("%s", var.environment)),
            map("Project", format("%s", var.project)),
            var.tags)}"
}

resource "aws_lb_listener_rule" "default" {
  count = "${var.enable_load_balanced ? 1 : 0}"

  listener_arn = "${var.listener_arn}"
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = "${aws_alb_target_group.target_group.arn}"
  }

  condition = ["${var.lb_listener_rule_condition}"]
}

resource "aws_alb_listener" "listener" {
  // Only enable if ALB is required
  count = "${var.enable_alb ? 1 : 0}"

  load_balancer_arn = "${aws_alb.alb.arn}"
  protocol          = "${var.alb_protocol}"
  port              = "${var.alb_port}"
  certificate_arn   = "${var.alb_certificate_arn}"
  ssl_policy        = "${var.alb_protocol == "HTTPS" ? "${var.ssl_policy}": ""}"

  default_action {
    target_group_arn = "${aws_alb_target_group.target_group.arn}"
    type             = "forward"
  }
}

resource "aws_route53_record" "dns_record" {
  // Only enable if ALB is required and dns_name is given
  // Note: checking if dns_name == "" did not work here...
  count = "${var.enable_alb ? var.enable_dns : 0}"

  name    = "${var.dns_name}"
  zone_id = "${var.dns_zone_id}"
  type    = "A"

  alias {
    name                   = "${aws_alb.alb.dns_name}"
    zone_id                = "${aws_alb.alb.zone_id}"
    evaluate_target_health = true
  }
}
