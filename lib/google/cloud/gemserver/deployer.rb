# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "google/cloud/gemserver"
require "fileutils"
require "open3"

module Google
  module Cloud
    module Gemserver
      ##
      #
      # # Deployer
      #
      # Manages the deployment of the gemserver to Google Cloud Platform.
      #
      class Deployer

        ##
        # Indicates that the pod has started correctly and the gemserver is
        # running.
        VALID_POD_STATUS = "Running".freeze

        ##
        # The name of the gemserver docker image.
        IMAGE_NAME = "gemserver-image".freeze

        ##
        # Initializes the Configuration object used by Deployer to deploy the
        # gemserver with the correct parameters.
        def initialize
          @config = Configuration.new
        end

        ##
        # Deploys the gemserver on Google App Engine Flex or Google Container
        # Engine.
        def deploy
          @config.metadata[:platform] == "gke" ? deploy_to_gke : deploy_to_gae
        end

        private

        ##
        # @private Deploys the gemserver to Google App Engine Flex.
        def deploy_to_gae
          `gcloud app deploy #{Configuration::SERVER_PATH}/app.yaml -q`
        end

        ##
        # @private Creates a docker image, pushes it to Google Container
        # Registry, then deploys the image as a service on Google Container
        # Engine.
        def deploy_to_gke
          build_docker_image Configuration::SERVER_PATH do |location|
            push_docker_image location do |location|
              deploy_gke_image location
            end
          end
        end

        ##
        # @private Deploys a given docker image on Google Container Registry
        # as a service on Google Container Engine and verifies it is running.
        #
        # @param [String] image_location the url of the docker image on google
        # cloud registry.
        def deploy_gke_image image_location

          update_gke_deploy_config image_location
          create_cluster

          deploy_file = "#{Configuration::SERVER_PATH}/deployment.yaml"

          puts "Creating deployment"
          `kubectl create -f #{deploy_file}`

          puts "Exposing nodes"
          `kubectl expose deployment #{IMAGE_NAME} --type LoadBalancer --port 8080`

          wait_for_pods

          puts "The gemserver has been deployed to GKE!"
        end

        ##
        # @private Waits for all pods to have "Running" status.
        def wait_for_pods
          puts "Waiting for the service to start running..."
          pod_name = nil
          pod_status = nil
          keep_trying_till_true 300 do
            stdout = `kubectl get pods`
            pods_info = stdout.split("\n").drop(1)
            pods_info.each do |pod_info|
              pod_info = pod_info.split
              if pod_info[0].match IMAGE_NAME
                pod_name = pod_info[0]
                pod_status = pod_info[2] == VALID_POD_STATUS
                break
              end
            end
            pod_status
          end
        end

        ##
        # @private Prepares a Dockerfile and builds a docker image from it.
        #
        # @param [String] app_dir The directory containing the gemserver files.
        #
        # @yield [image_location] The image location
        # @yieldparam image_location [String] The url of the docker image on
        # Google Container Registry.
        def build_docker_image app_dir
          image_location = "us.gcr.io/#{@config[:proj_id]}/#{IMAGE_NAME}"

          begin
            FileUtils.cp ENV["GEMSERVER_CREDS"], app_dir
            if File.file? "Dockerfile"
              puts "The Dockerfile file already exists."
            else
              File.open "#{app_dir}/Dockerfile.base" do |source_file|
                FileUtils.touch "#{app_dir}/Dockerfile"
                File.open "#{app_dir}/Dockerfile", "w" do |dest_file|
                  service_account = ENV["GEMSERVER_CREDS"].split("/").pop
                  file_content = source_file.read % {
                    service_account_name: "/app/#{service_account}"
                  }
                  dest_file.write file_content
                end
              end
            end

            puts "Building image #{IMAGE_NAME} at #{image_location}"
            `docker build -t #{image_location} #{app_dir}`
            yield image_location
          ensure
            puts "docker rmi #{image_location}"
            Open3.capture3 "docker rmi #{image_location}"
          end
        end

        ##
        # @private Pushes a docker image to Google Container Registry.
        #
        # @param [String] image_location The url of the docker image on
        # Google Container Registry.
        #
        # @yield [image_location] The image name and image location
        # @yieldparam image_location [String] The url of the docker image on
        # Google Container Registry.
        def push_docker_image image_location
          begin
            puts "pushing #{IMAGE_NAME} to #{image_location}"
            `gcloud docker -- push #{image_location}`
            yield image_location
          ensure
            `gsutil rm -r gs://us.artifacts.#{@config[:proj_id]}.appspot.com/containers/repositories/library/#{IMAGE_NAME}/`
          end
        end

        ##
        # @private Creates a cluster of pods if the cluster does not already
        # exist. The credentials of the cluster are fetched afterwards.
        def create_cluster
          puts "Creating cluster..."
          name = user_input "Enter the name of cluster. If it does "\
            "not exist it will be created."
          zone = user_input "Enter the zone of the cluster. Options can be "\
            "found here: "\
            "https://cloud.google.com/compute/docs/regions-zones/regions-zones"
          unless cluster_exists? name, zone
            `gcloud container clusters create #{name} --zone #{zone}`
            fail "Cluster creation error." unless $?.exitstatus == 0
          end
          `gcloud container clusters get-credentials #{name} --zone #{zone}`
        end

        ##
        # @private Creates a deployment file containing the specifications for
        # the pods / containers the gemserver runs in.
        # 
        # @param [String] image_location The location of the image used for the
        # gemserver.
        def update_gke_deploy_config image_location
          return unless image_location

          deploy_file = "#{Configuration::SERVER_PATH}/deployment.yaml"
          base_file = "#{Configuration::SERVER_PATH}/deployment.yaml.base"
          command = [
            "/cloud_sql_proxy",
            "--dir=/cloudsql",
            "-instances=#{@config.app["beta_settings"]["cloud_sql_instances"]}",
            "-credential_file=/secrets/cloudsql/credentials.json"
          ]

          if File.file? deploy_file
            puts "#{deploy_file} already exists. Skipping pod configuration."
          else
            File.open base_file do |source_file|
              File.open deploy_file, "w" do |dest_file|
                file_content = source_file.read % {
                  image_name: IMAGE_NAME,
                  image_location: image_location,
                  sql_proxy_command: command
                }
                dest_file.write file_content
              end
            end
          end
        end

        ##
        # @private Checks if a given cluster in a given zone already exists.
        #
        # @param [String] name The name of the cluster.
        #
        # @param [String] zone The zone the cluster is in.
        #
        # @return [Boolean]
        def cluster_exists? name, zone
          clsr = `gcloud container clusters list`.split("\n")
          (1..clsr.size-1).each do |i|
            clsr_info = clsr[i].split
            return true if clsr_info[0] == name && clsr_info[1] == zone
          end
          false
        end

        ##
        # @private Runs a block of code until it returns true or raises an
        # error.
        #
        # @param [Fixnum] timeout The limit for how long a block of code is
        # executed.
        def keep_trying_till_true timeout = 30
          t_begin = Time.now
          loop do
            if yield
              break
            elsif (Time.now - t_begin) > timeout
              fail "Timeout after trying for #{timeout} seconds"
            else
              sleep 1
            end
          end
        end

        ##
        # @private Display a prompt and get user input.
        #
        # @param [String] prompt The prompt displayed to the user.
        #
        # @return [String]
        def user_input prompt
          puts prompt
          STDIN.gets.chomp
        end
      end
    end
  end
end
