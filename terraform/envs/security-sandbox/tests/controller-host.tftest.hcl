mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { region = "ap-northeast-2" } }
}
variables {
  aws_account_id                = "123456789012"
  operator_ssh_cidr             = "192.0.2.1/32"
  publisher_principal_arn       = "arn:aws:iam::123456789012:user/test-operator"
  github_builder_role_name      = null
  github_artifacts_bucket_arn   = null
  enable_controller_host        = false
  controller_bootstrap_complete = false
  controller_operator_ssh_cidr  = null
}
run "controller_is_not_created_implicitly" {
  command = plan
  assert {
    condition     = length(aws_instance.controller) == 0 && length(aws_eip.controller) == 0
    error_message = "Do not create a paid controller unless explicitly enabled."
  }
}
run "separate_network_no_instance_credentials_and_explicit_operator" {
  command = plan
  variables {
    enable_controller_host       = true
    controller_ami_id            = "ami-0123456789abcdef0"
    controller_ssh_public_key    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakePublicTestKeyOnly"
    controller_operator_ssh_cidr = "198.51.100.2/32"
  }
  assert {
    condition     = aws_vpc.controller[0].cidr_block == "10.243.0.0/24" && aws_instance.controller[0].iam_instance_profile == "" && aws_instance.controller[0].root_block_device[0].encrypted
    error_message = "The trusted controller must use its own network and encrypted disk, with no instance role."
  }
  assert {
    condition     = one(aws_security_group.controller[0].ingress).cidr_blocks == tolist(["198.51.100.2/32"]) && one(aws_security_group.controller[0].ingress).from_port == 22
    error_message = "Controller operator access must not inherit the guest-controller SSH address."
  }
}
run "metadata_is_sealed_after_trusted_bootstrap" {
  command = plan
  variables {
    enable_controller_host        = true
    controller_ami_id             = "ami-0123456789abcdef0"
    controller_ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakePublicTestKeyOnly"
    controller_bootstrap_complete = true
  }
  assert {
    condition     = aws_instance.controller[0].metadata_options[0].http_endpoint == "disabled" && aws_instance.controller[0].metadata_options[0].http_tokens == "required"
    error_message = "Seal the metadata endpoint explicitly after trusted bootstrap."
  }
}
