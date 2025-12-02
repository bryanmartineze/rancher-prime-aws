# Use the default VPC
data "aws_vpc" "default" {
  default = true
}

# Fetch an available subnet in a specific AZ in the default VPC
data "aws_subnet" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "availability-zone"
    values = ["us-east-1a"]
  }
}

# Data source to fetch the latest SLES 15 SP6 AMI
data "aws_ami" "suse-sles-15-sp6" {
  most_recent = true

  owners = ["013907871322"]  # SUSE owner ID

  filter {
    name   = "name"
    values = ["suse-sles-15-sp6*x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Security Group for instances
resource "aws_security_group" "rancher_sg" {
  name        = "rancher_security_group"
  description = "Allow ssh, https, and internal traffic"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

    ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = [data.aws_vpc.default.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create a single instance
resource "aws_instance" "rancher_instance" {
  ami                    = data.aws_ami.suse-sles-15-sp6.id
  instance_type          = "t3a.large"
  subnet_id              = data.aws_subnet.default.id
  key_name               = "linux" 
  vpc_security_group_ids = [aws_security_group.rancher_sg.id]

  root_block_device {
    delete_on_termination = true
    volume_size           = 30
    volume_type           = "gp3"
  }

    tags = {
    Name = "rancher-server"
  }

}


# Elastic IP for the instance
resource "aws_eip" "rancher_eip" {
  instance = aws_instance.rancher_instance.id
}

# Associate the Elastic IP with the instance
resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.rancher_instance.id
  allocation_id = aws_eip.rancher_eip.id
}

# Install RKE2, Cert-Manager, and Rancher on the instance
resource "null_resource" "install_rancher" {
  depends_on = [aws_eip_association.eip_assoc]  # Ensure EIP is attached

  connection {
    type        = "ssh"
    host        = aws_eip.rancher_eip.public_dns
    user        = "ec2-user"
    private_key = file("/home/ec2-user/rancher-demo-aws/linux.pem") #Configure where is your ssh key
  }

  # Provisioner to install RKE2
  provisioner "remote-exec" {
    inline = [

      # Creates the RKE2 directory
      "sudo mkdir -p /etc/rancher/rke2/",

      # Creates the RKE2 config file
      "echo 'token: rke2SecurePassword' | sudo tee /etc/rancher/rke2/config.yaml > /dev/null",

      # Download and install RKE2 in server mode
      "sudo sh -c 'curl -sfL https://get.rke2.io | INSTALL_RKE2_CHANNEL=v1.33 INSTALL_RKE2_TYPE=server sh -'",

      "sleep 60",  # Wait for RKE2 installation to complete

      # Enable and start the RKE2 server service
      "sudo systemctl enable rke2-server.service && sudo systemctl start rke2-server.service",

      "sleep 240",  # Wait for the server to start

      # Update permissions on rke2.yaml to allow ec2-user access
      "sudo chmod 644 /etc/rancher/rke2/rke2.yaml",

      # Create symlinks for kubectl and containerd
      "sudo ln -s /var/lib/rancher/rke2/data/v1*/bin/kubectl /usr/bin/kubectl",
      "sudo ln -s /var/run/k3s/containerd/containerd.sock /var/run/containerd/containerd.sock",

      # Update .bashrc for path and aliases
      "echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin/' | sudo tee -a /home/ec2-user/.bashrc > /dev/null",
      "echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' | sudo tee -a /home/ec2-user/.bashrc > /dev/null",
      "echo 'export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml' | sudo tee -a /home/ec2-user/.bashrc > /dev/null",
      "echo 'alias k=kubectl' | sudo tee -a /home/ec2-user/.bashrc > /dev/null",

      # Source .bashrc to apply changes
      "source ~/.bashrc",

      # Test kubectl
      "kubectl get nodes",

  
      # Download and install Helm
      "sudo mkdir -p /opt/rancher/helm",
      "cd /opt/rancher/helm",
      "sudo curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3",
      "sudo chmod 755 get_helm.sh && ./get_helm.sh",
      "sudo mv /usr/local/bin/helm /usr/bin/helm",

      # Add and update Helm repositories
      "helm repo add jetstack https://charts.jetstack.io",
      "helm repo add rancher-prime https://charts.rancher.com/server-charts/prime",
      "helm repo update",

      #Wait for the helm repo to update
      "sleep 20",

      # Create the namespace for Cert Manager and install Cert Manager
      "kubectl create namespace cert-manager",
      "helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.19.1 --namespace cert-manager --create-namespace --set crds.enabled=true" ,

      "sleep 60",  # Wait for Cert Manager installation

      # Verify the status of Cert Manager
      "kubectl get pods --namespace cert-manager",

      # Create the namespace for Rancher and install Rancher
      "kubectl create namespace cattle-system",
      "helm upgrade -i rancher rancher-prime/rancher --namespace cattle-system --set bootstrapPassword=rancherSecurePassword --set hostname=rancher.${aws_eip.rancher_eip.public_ip}.sslip.io",
      
      "sleep 200",  # Wait until rancher installation is complete

      # Verify the status of Rancher Manager
      "kubectl get pods --namespace cattle-system"

    ]
 }
}

# Output for Rancher URL
output "rancher_url" {
  value       = "rancher.${aws_eip.rancher_eip.public_ip}.sslip.io"
  description = "URL to access the Rancher server"
}
