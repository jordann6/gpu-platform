terraform {
  backend "s3" {
    bucket       = "tf-backend-jord-projs"
    key          = "gpu-platform/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
