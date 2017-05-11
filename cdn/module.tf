terraform {
  required_version = ">= 0.8.1"
}

variable "az" {
  type = "map"

  default = {
    "eu-west-1"      = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
    "eu-west-2"      = ["eu-west-2a", "eu-west-2b"]
    "eu-central-1"   = ["eu-central-1a", "eu-central-1b"]
    "ca-central-1"   = ["ca-central-1a", "ca-central-1b"]
    "us-east-1"      = ["us-east-1a", "us-east-1c", "us-east-1d", "us-east-1e"]
    "us-east-2"      = ["us-east-2a", "us-east-2b", "us-east-2c"]
    "us-west-1"      = ["us-west-1b", "us-west-1c"]
    "us-west-2"      = ["us-west-2a", "us-west-2b", "us-west-2c"]
    "ap-northeast-1" = ["ap-northeast-1b", "ap-northeast-1c"]
    "ap-northeast-2" = ["ap-northeast-2a", "ap-northeast-2c"]
    "ap-southeast-1" = ["ap-southeast-1a", "ap-southeast-1b"]
    "ap-southeast-2" = ["ap-southeast-2b", "ap-southeast-2c"]
    "ap-south-1"     = ["ap-south-1a", "ap-south-1b"]
    "sa-east-1"      = ["sa-east-1a", "sa-east-1c"]
  }
}

provider "aws" {
  region = "${var.region}"
}

/*
TODO: once https://github.com/hashicorp/terraform/issues/1497 is addressed
data "aws_availability_zones" "available" {
  state = "available"
}
*/

data "aws_route53_zone" "default" {
  zone_id = "${var.r53_zone_id}"
}

data "aws_ami" "default" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn-ami-hvm-2016.09*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  owners = ["amazon"]
}

resource "aws_vpc" "main" {
  cidr_block                       = "192.168.0.0/16"
  assign_generated_ipv6_cidr_block = "true"
  enable_dns_support               = "true"
  enable_dns_hostnames             = "true"

  tags {
    Name = "cdn-${var.region}"
  }
}

resource "aws_internet_gateway" "default" {
  vpc_id = "${aws_vpc.main.id}"

  tags = {
    Name = "cdn-${var.region}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                          = "${aws_vpc.main.id}"
  cidr_block                      = "${cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)}"
  ipv6_cidr_block                 = "${cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, count.index)}"
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true
  availability_zone               = "${element(var.az[var.region], count.index)}"
  count                           = "${length(var.az[var.region])}"

  tags = {
    Name = "cdn-${element(var.az[var.region], count.index)}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.main.id}"
  count  = "${length(var.az[var.region])}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.default.id}"
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = "${aws_internet_gateway.default.id}"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = "${element(aws_subnet.public.*.id, count.index)}"
  route_table_id = "${element(aws_route_table.public.*.id, count.index)}"
  count          = "${length(var.az[var.region])}"
}

resource "aws_security_group" "default" {
  vpc_id = "${aws_vpc.main.id}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_instance" "server" {
  count                  = "${length(var.az[var.region]) * var.servers_per_az}"
  instance_type          = "${var.instance_type}"
  ami                    = "${data.aws_ami.default.id}"
  subnet_id              = "${element(aws_subnet.public.*.id, count.index)}"
  ipv6_address_count     = "1"
  vpc_security_group_ids = ["${aws_security_group.default.id}", "${aws_vpc.main.default_security_group_id}"]

  tags = {
    Name = "cdn-server-${element(var.az[var.region], count.index)}-${count.index}"
  }
}

resource "aws_route53_record" "cdnv4" {
  zone_id        = "${data.aws_route53_zone.default.zone_id}"
  name           = "${format("%s.%s", var.r53_domain_name, data.aws_route53_zone.default.name)}"
  type           = "A"
  ttl            = "60"
  records        = ["${aws_instance.server.*.public_ip}"]
  set_identifier = "cdn-${var.region}-v4"

  latency_routing_policy {
    region = "${var.region}"
  }
}

resource "aws_route53_record" "cdnv6" {
  zone_id        = "${data.aws_route53_zone.default.zone_id}"
  name           = "${format("%s.%s", var.r53_domain_name, data.aws_route53_zone.default.name)}"
  type           = "AAAA"
  ttl            = "60"
  records        = ["${aws_instance.server.*.ipv6_addresses.0}"]
  set_identifier = "cdn-${var.region}-v6"

  latency_routing_policy {
    region = "${var.region}"
  }
}
