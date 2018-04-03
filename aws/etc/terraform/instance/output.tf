output "stardog_contact" {
  value = "${aws_alb.stardog_alb.dns_name}"
}

output "stardog_internal_contact" {
  value = "${aws_alb.stardog_alb_internal.dns_name}"
}

output "bastion_contact" {
  value = "${aws_elb.bastion.dns_name}"
}

output "zookeeper_nodes" {
  value = ["${aws_elb.zookeeper.*.dns_name}"]
}