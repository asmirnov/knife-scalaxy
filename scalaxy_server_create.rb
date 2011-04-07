#
# Author:: 
# Copyright:: 
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife'
require 'chef/json_compat'
require 'uuidtools'

class Chef
  class Knife
    class ScalaxyServerCreate < Knife

      banner "knife scalaxy server create [RUN LIST...] (options)"

      option :flavor,
        :short => "-f FLAVOR",
        :long => "--flavor FLAVOR",
        :description => "The flavor of server",
        :proc => Proc.new { |f| f.to_i },
        :default => 2

      option :root_size,
        :short => "-R SIZE",
        :long => "--root-size SIZE",
        :description => "The size of root",
        :proc => Proc.new { |f| f.to_i },
        :default => 3*1024*1024*1024

      option :image,
        :short => "-i IMAGE",
        :long => "--image IMAGE",
        :description => "The image of the server",
        :proc => Proc.new { |i| i.to_i },
        :default => 2

      option :server_name,
        :short => "-S NAME",
        :long => "--server-name NAME",
        :description => "The server name. Defaults to a random UUID.",
        :default => UUIDTools::UUID.random_create.to_s

      option :chef_node_name,
        :short => "-N NAME",
        :long => "--node-name NAME",
        :description => "The Chef node name for your new node"

      option :ssh_user,
        :short => "-x USERNAME",
        :long => "--ssh-user USERNAME",
        :description => "The ssh username",
        :default => "root"

      option :ssh_password,
        :short => "-P PASSWORD",
        :long => "--ssh-password PASSWORD",
        :description => "The ssh password"

      option :api_key,
        :short => "-K KEY",
        :long => "--scalaxy-api-key KEY",
        :description => "Your scalaxy API key (password)",
        :proc => Proc.new { |key| Chef::Config[:knife][:scalaxy_api_key] = key } 

      option :api_username,
        :short => "-A USERNAME",
        :long => "--scalaxy-api-username USERNAME",
        :description => "Your scalaxy API username (email)",
        :proc => Proc.new { |username| Chef::Config[:knife][:scalaxy_api_username] = username } 

      option :prerelease,
        :long => "--prerelease",
        :description => "Install the pre-release chef gems"

      option :distro,
        :short => "-d DISTRO",
        :long => "--distro DISTRO",
        :description => "Bootstrap a distro using a template",
        :default => "ubuntu10.04-gems"

      option :template_file,
        :long => "--template-file TEMPLATE",
        :description => "Full path to location of template to use",
        :default => false

      def h
        @highline ||= HighLine.new
      end
      
      def tcp_test_ssh(hostname)
        tcp_socket = TCPSocket.new(hostname, 22)
        readable = IO.select([tcp_socket], nil, nil, 5)
        if readable
          Chef::Log.debug("sshd accepting connections on #{hostname}, banner is #{tcp_socket.gets}")
          yield
          true
        else
          false
        end
      rescue Errno::ETIMEDOUT
        false
      rescue Errno::ECONNREFUSED
        sleep 2
        false
      ensure
        tcp_socket && tcp_socket.close
      end

      def run 
        require 'highline'
        require 'net/ssh/multi'
        require 'readline'


        $stdout.sync = true

# Some spaghetti just to prove the concept

        require 'net/http'
        require 'net/https'
        require 'json'

        api_url = "https://www.scalaxy.ru/api/"
        api_username = config[:api_username]
        api_key = config[:api_key]

        uri = URI.parse(api_url)
        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE	

        # get a list of projects for the :api_username
	request = Net::HTTP::Get.new(uri.request_uri+"projects.json")
	request.basic_auth api_username, api_key	

        response = http.request(request)

	raise response.to_s+response.body unless (response.class == Net::HTTPOK)

        projects = JSON.parse(response.body)        

        raise "No project found!" if projects.empty?

        # assume there is always only one project per account
        proj_id = projects.first['id']

        raise "Bad project id" unless (proj_id.is_a?(Integer) && (proj_id > 0))

        # get a list of ip addresses
	request = Net::HTTP::Get.new(uri.request_uri+"ip_addresses.json")
	request.basic_auth api_username, api_key	

        response = http.request(request)

	raise response.to_s+response.body unless (response.class == Net::HTTPOK)

        ip_addresses = JSON.parse(response.body)

        ip = ip_addresses.find {|ip| ip['instance_id'].nil?}
        ip_id = ip['id']

        raise "No IP address available!" unless (ip_id.is_a?(Integer) && (ip_id > 0))

        instance_params = {
                'name' => config[:server_name],
                'slots' => config[:flavor],
                'max_slots' => 16,
                'min_slots' => 1,
                'root_size' => config[:root_size],
                'os_image_id' => config[:image],
                'password' => config[:ssh_password],
                'ip_external_id' => ip_id
        }

        # create instance
	request = Net::HTTP::Post.new(uri.request_uri+"projects/"+proj_id.to_s+"/instances.json")
	request.basic_auth api_username, api_key	
        request.add_field('Content-Type', 'application/json')
        request.body = JSON.generate(instance_params)
        
        response = http.request(request)

	raise response.to_s+response.body unless (response.class == Net::HTTPCreated)

        server = JSON.parse(response.body)

        # poll api until instance is ready
	request = Net::HTTP::Get.new(uri.request_uri+"projects/"+proj_id.to_s+"/instances/"+server["id"].to_s+".json")
	request.basic_auth api_username, api_key	

        sleep 2 until (JSON.parse(http.request(request).body)["current_status"] == "stopped")

        # power on
	request = Net::HTTP::Put.new(uri.request_uri+"projects/"+proj_id.to_s+"/instances/"+server["id"].to_s+"/run.json")
	request.basic_auth api_username, api_key	
        request.add_field('Content-Type', 'application/json')
        request.body = ""

        response = http.request(request)
	raise response.to_s+response.body unless (response.class == Net::HTTPOK)

        server = {
                "ip" => ip["ip_string"],
                "id" => config[:server_name]
        }

        print "\n#{h.color("Waiting for sshd", :magenta)}"

        print(".") until tcp_test_ssh(server["ip"]) { sleep @initial_sleep_delay ||= 10; puts("done") }

        bootstrap_for_node(server).run

        
      end

      def bootstrap_for_node(server)
        bootstrap = Chef::Knife::Bootstrap.new
        bootstrap.name_args = [server["ip"]]
        bootstrap.config[:run_list] = @name_args
        bootstrap.config[:ssh_user] = config[:ssh_user] || "root"
        bootstrap.config[:ssh_password] = config[:ssh_password]
        bootstrap.config[:identity_file] = config[:identity_file]
        bootstrap.config[:chef_node_name] = config[:chef_node_name] || server["id"]
        bootstrap.config[:prerelease] = config[:prerelease]
        bootstrap.config[:distro] = config[:distro]
        bootstrap.config[:use_sudo] = true
        bootstrap.config[:template_file] = config[:template_file]
        bootstrap.config[:environment] = config[:environment]
        bootstrap
      end
    end
  end
end


