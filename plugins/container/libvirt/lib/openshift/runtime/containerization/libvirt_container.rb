require 'openshift-origin-node/utils/node_logger'
require 'ipaddr'

module OpenShift
  module Runtime
    module Containerization
      class Plugin
        include OpenShift::Runtime::NodeLogger
        CONF_DIR = '/etc/openshift/'

        attr_reader :gear_shell, :mcs_label

        def self.container_dir(container)
          File.join(container.base_dir,'gear',container.uuid)
        end

        ##
        # Public: Initialize a LibVirt Sandbox based container plugin
        #
        # Configuration for this container is kept in /etc/openshift/container-libvirt.conf.
        # Config variables:
        #   LIBVIRT_PRIVATE_IP_RANGE:
        #     IP range to use when assigning container IP addresses. Eg: 172.16.0.0/12
        #   LIBVIRT_PRIVATE_IP_ROUTE:
        #     Default route for the container. Eg: 172.16.0.0/12
        #   LIBVIRT_PRIVATE_IP_GW:
        #     The gateway IP address. This is the IP of the host machine on the VLan. Eg: 172.16.0.1
        #
        # @param [ApplicationContainer] application_container The parent container object for this plugin.
        def initialize(application_container)
          @container  = application_container
          @config     = OpenShift::Config.new
          @container_config     = OpenShift::Config.new(File.join(CONF_DIR, "container-libvirt.conf"))
          @gear_shell = "/usr/bin/virt-login-shell"
          @mcs_label  = OpenShift::Runtime::Utils::SELinux.get_mcs_label(@container.gid) if @container.uid

          @port_begin = (@config.get("PORT_BEGIN") || "35531").to_i
          @ports_per_user = (@config.get("PORTS_PER_USER") || "5").to_i
          @uid_begin = (@config.get("GEAR_MIN_UID") || "500").to_i
          @container_metadata = File.join(@container.base_dir, ".container", @container.uuid)
        end

        ##
        # Public: Creates a new new POSIX user and group. Initialized a new LibVirt Sandbox based container and
        # creates the basic layout of a OpenShift gear. The container will be started at the before this method
        # returns. You can query the list of available containers with:
        #   virsh -c lxc:/// list --all
        #
        # If the container is not passed a UID, we attempt to generate a UID/GID.
        def create
          unless @container.uid
            @container.uid = @container.gid = @container.next_uid
            @mcs_label  = OpenShift::Runtime::Utils::SELinux.get_mcs_label(@container.gid)
          end

          cmd = %{groupadd -g #{@container.gid} \
          #{@container.uuid}}
          out,err,rc = ::OpenShift::Runtime::Utils::oo_spawn(cmd)
          raise ::OpenShift::Runtime::UserCreationException.new(
                    "ERROR: unable to create group for user account(#{rc}): #{cmd.squeeze(" ")} stdout: #{out} stderr: #{err}"
                ) unless rc == 0

          FileUtils.mkdir_p @container.container_dir
          cmd = %{useradd -u #{@container.uid} \
                  -g #{@container.gid} \
                  -d #{@container.container_dir} \
                  -s /bin/bash \
                  -c '#{@container.gecos}' \
                  -m \
                  -N \
                  -k #{@container.skel_dir} \
          #{@container.uuid}}
          if @container.supplementary_groups
            cmd << %{ -G "openshift,#{@container.supplementary_groups}" }
          else
            cmd << %{ -G "openshift" }
          end
          out,err,rc = ::OpenShift::Runtime::Utils::oo_spawn(cmd)
          raise ::OpenShift::Runtime::UserCreationException.new(
                    "ERROR: unable to create user account(#{rc}): #{cmd.squeeze(" ")} stdout: #{out} stderr: #{err}"
                ) unless rc == 0

          set_ro_permission(@container.container_dir)
          FileUtils.chmod 0o0750, @container.container_dir

          FileUtils.mkdir_p(@container_metadata)
          File.open(File.join(File.join(@container_metadata, "container-id")), "w") do |f|
            f.write(@container.uuid)
          end
          File.open(File.join(File.join(@container_metadata, "interfaces.json")), "w") do |f|
            f.write("[]\n")
          end
          set_ro_permission_R(@container_metadata)

          security_field = "static,label=unconfined_u:system_r:openshift_t:#{@mcs_label}"
          external_ip_addr = "#{get_nat_ip_address}/#{get_nat_ip_mask}"
          external_ip_mask = get_nat_ip_mask
          route            = @container_config.get('LIBVIRT_PRIVATE_IP_ROUTE')
          gw               = @container_config.get('LIBVIRT_PRIVATE_IP_GW')

          cmd = "/usr/bin/virt-sandbox-service create " +
              "-U #{@container.uid} -G #{@container.gid} " +
              "-p #{File.join(@container.base_dir,'gear')} -s #{security_field} " +
              "-N address=#{external_ip_addr}," +
              "route=#{route}%#{gw} " +
              "-f openshift_var_lib_t " +
              "-m host-bind:/dev/container-id=#{@container_metadata}/container-id " +
                 "host-bind:/proc/meminfo=/proc/meminfo " +
              " -- " +
              "#{@container.uuid} /usr/sbin/oo-gear-init"
          out, err, rc = ::OpenShift::Runtime::Utils::oo_spawn(cmd)
          raise ::OpenShift::Runtime::UserCreationException.new( "Failed to create lxc container. rc=#{rc}, out=#{out}, err=#{err}" ) if rc != 0

          container_link = File.join(@container.container_dir, @container.uuid)
          FileUtils.ln_s(File.join(@container.base_dir,'gear'), container_link)
          set_ro_permission(container_link)

          @container.initialize_homedir(@container.base_dir, @container.container_dir)

          start
        end

        ##
        # Public: Starts the LibVirt Sandbox based container and re-initialized the forwarding rules and proxy mappings.
        # This is the equavalent of unidling the container.
        #
        # If the container is already running, this method will reload the network mappings for the container.
        def start(option={})
          if option[:skip_start] != true
            out, err, rc = ::OpenShift::Runtime::Utils::oo_spawn("/usr/bin/virsh -c lxc:/// start #{@container.uuid} < /dev/null &")
            raise Exception.new( "Failed to start lxc container. rc=#{rc}, out=#{out}, err=#{err}" ) if rc != 0
          end
        end

        def post_start(option={})
          #Wait for container to become available
          for i in 1..10
            sleep 1
            begin
              next if not container_running?
              _,_,rc = run_in_container_context("echo 0")
              break if  rc == 0
            rescue => e
              #ignore
            end
          end

          _,_,rc = run_in_container_context("echo 0")
          raise Exception.new( "Failed to start lxc container. rc=#{rc}" ) if rc != 0

          reload_network
        end

        ##
        # Public: Destroys the LibVirt Sandbox based container and deletes the associated POSIX user and group.
        # If the container is running, it will be stopped and all processed killed before it is destroyed.
        # This method will also clean up firewalld forwarding rules and HTTP proxy mappings.
        def destroy
          if container_exists?
            stop() if container_running?

            out, err, rc = ::OpenShift::Runtime::Utils::oo_spawn("/usr/bin/virt-sandbox-service delete #{@container.uuid}")
            raise Exception.new( "Failed to delete lxc container. rc=#{rc}, out=#{out}, err=#{err}" ) if rc != 0

            FileUtils.rm_rf @container_metadata
          end

          last_access_dir = @config.get("LAST_ACCESS_DIR")
          ::OpenShift::Runtime::Utils::oo_spawn("rm -f #{last_access_dir}/#{@container.name} > /dev/null")
          delete_all_public_endpoints

          if @config.get("CREATE_APP_SYMLINKS").to_i == 1
            Dir.foreach(File.dirname(@container.container_dir)) do |dent|
              unobfuscate = File.join(File.dirname(@container.container_dir), dent)
              if (File.symlink?(unobfuscate)) &&
                  (File.readlink(unobfuscate) == File.basename(@container.container_dir))
                File.unlink(unobfuscate)
              end
            end
          end

          OpenShift::Runtime::FrontendHttpServer.new(@container).destroy

          dirs = list_home_dir(@container.container_dir)
          begin
            user = Etc.getpwnam(@container.uuid)

            cmd = "userdel --remove -f \"#{@container.uuid}\""
            out,err,rc = ::OpenShift::Runtime::Utils::oo_spawn(cmd)
            raise ::OpenShift::Runtime::UserDeletionException.new(
                      "ERROR: unable to delete user account(#{rc}): #{cmd} stdout: #{out} stderr: #{err}"
                  ) unless rc == 0
          rescue ArgumentError => e
            logger.debug("user does not exist. ignore.")
          end

          begin
            group = Etc.getgrnam(@container.uuid)

            cmd = "groupdel \"#{@container.uuid}\""
            out,err,rc = ::OpenShift::Runtime::Utils::oo_spawn(cmd)
            raise ::OpenShift::Runtime::UserDeletionException.new(
                      "ERROR: unable to delete group of user account(#{rc}): #{cmd} stdout: #{out} stderr: #{err}"
                  ) unless rc == 0
          rescue ArgumentError => e
            logger.debug("group does not exist. ignore.")
          end

          # 1. Don't believe everything you read on the userdel man page...
          # 2. If there are any active processes left pam_namespace is not going
          #      to let polyinstantiated directories be deleted.
          FileUtils.rm_rf(@container.container_dir)
          if File.exists?(@container.container_dir)
            # Ops likes the verbose verbage
            logger.warn %Q{
1st attempt to remove \'#{@container.container_dir}\' from filesystem failed.
Dir(before)   #{@container.uuid}/#{@container.uid} => #{dirs}
Dir(after)    #{@container.uuid}/#{@container.uid} => #{list_home_dir(@container.container_dir)}
                        }
          end

          # try one last time...
          if File.exists?(@container.container_dir)
            sleep(5)                    # don't fear the reaper
            FileUtils.rm_rf(@container.container_dir)   # This is our last chance to nuke the polyinstantiated directories
            logger.warn("2nd attempt to remove \'#{@container.container_dir}\' from filesystem failed.") if File.exists?(@container.container_dir)
          end
        end

        ##
        # Public: Stops the LibVirt Sandbox based container but does not destroy it. This is the equavalent of
        # Idling the container.
        def stop(option={})
          out, err, rc = ::OpenShift::Runtime::Utils::oo_spawn("/usr/bin/virsh -c lxc:/// shutdown #{@container.uuid}")
          raise Exception.new( "Failed to stop lxc container. rc=#{rc}, out=#{out}, err=#{err}" ) if rc != 0
        end

        def boost(&block)
          yield block
        end

        ##
        # Public: Deterministically constructs an IP address for the given UID based on the given
        # host identifier (LSB of the IP). The host identifier must be a value between 1-127
        # inclusive.
        #
        # The global user IP range begins at 0x7F000000.
        #
        # @param [Integer] host_id A unique numberic ID for a cartridge mapping
        # @return an IP address string in dotted-quad notation.
        def get_ip_addr(host_id)
          raise "Invalid host_id specified" unless host_id && host_id.is_a?(Integer)

          if host_id < 1 || host_id > 127
            raise "Supplied host identifier #{host_id} must be between 1 and 127"
          end
          "169.254.169." + host_id.to_s
        end

        ##
        # Public: Given a private IP and port within the container, creates iptables/firewall rules to forward
        # traffic to the external IP of the host machine.
        #
        # @param private_ip [String] Container internal IP that the service is bound to in dotted quad notation.
        # @param private_port [String] Port number that the service is bound to in dotted quad notation.
        # @return [Integer] public port number that the service has been forwarded to.
        def create_public_endpoint(private_ip, private_port)
          container_ip   = get_nat_ip_address
          public_port    = get_open_proxy_port
          node_ip        = @config.get('PUBLIC_IP')

          create_iptables_rules(:add, public_port, container_ip, node_ip, private_ip, private_port)

          public_port
        end

        ##
        # Public: Given a list of proxy mappings, removes any iptables/firewall rules that are forwarding traffic.
        #
        # @param proxy_mappings [Array] Array of proxy mappings
        def delete_public_endpoints(proxy_mappings)
          proxy_mappings.each do |mapping|
            public_port  = mapping[:proxy_port]
            container_ip = get_nat_ip_address
            node_ip      = @config.get('PUBLIC_IP')
            private_ip   = mapping[:private_ip]
            private_port = mapping[:private_port]

            create_iptables_rules(:delete, public_port, container_ip, node_ip, private_ip, private_port)
          end
        end

        ##
        # Public: Removes all iptables/firewall rules that are forwarding traffic for this container
        def delete_all_public_endpoints
          delete_public_endpoints(@container.list_proxy_mappings)
        end

        ##
        # Public: Executes specified command inside the container and return its stdout, stderr and exit status or,
        # raise exceptions if certain conditions are not met. If executed from within a container, it does not
        # attempt to re-enter container context.
        #
        # The command is run within the container and is automiatically constrainged by SELinux context.
        # The environment variables are cleared and may be specified by :env.
        #
        # @param [String] command command line string which is passed to the standard shell
        # @param [Hash] options
        #   :env: hash
        #     name => val : set the environment variable
        #     name => nil : unset the environment variable
        #   :chdir => path             : set current directory when running command
        #   :expected_exitstatus       : An Integer value for the expected return code of command
        #                              : If not set spawn() returns exitstatus from command otherwise
        #                              : raise an error if exitstatus is not expected_exitstatus
        #   :timeout                   : Maximum number of seconds to wait for command to finish. default: 3600
        #                              : stdin for the command is /dev/null
        #   :out                       : If specified, STDOUT from the child process will be redirected to the
        #                                provided +IO+ object.
        #   :err                       : If specified, STDERR from the child process will be redirected to the
        #                                provided +IO+ object.
        #
        # @return [Array] stdout, stderr, exit status
        #
        # NOTE: If the +out+ or +err+ options are specified, the corresponding return value from +oo_spawn+
        # will be the incoming/provided +IO+ objects instead of the buffered +String+ output. It's the
        # responsibility of the caller to correctly handle the resulting data type.
        def run_in_container_context(command, options = {})
          require 'openshift-origin-node/utils/selinux'
          options[:unsetenv_others] = true
          options[:force_selinux_context] = false

          if options[:env].nil? or options[:env].empty?
            options[:env] = ::OpenShift::Runtime::Utils::Environ.for_gear(@container.container_dir)
          end

          if not File.exists?("/dev/container-id")
            command = "cd #{options[:chdir]} ; #{command}" if options[:chdir]
            options.delete :uid

            command.gsub!()
            command = %Q{/usr/bin/virt-sandbox-service execute #{@container.uuid} -- /sbin/runuser -s /bin/bash #{@container.uuid} -c '#{command}'}
            OpenShift::Runtime::Utils::oo_spawn(command, options)
          else
            options[:uid] = @container.uid
            OpenShift::Runtime::Utils::oo_spawn(command, options)
          end
        end

        def reset_permission(*paths)
          OpenShift::Runtime::Utils::SELinux.clear_mcs_label(paths)
          OpenShift::Runtime::Utils::SELinux.set_mcs_label(@mcs_label, paths)
        end

        def reset_permission_R(*paths)
          OpenShift::Runtime::Utils::SELinux.clear_mcs_label_R(paths)
          OpenShift::Runtime::Utils::SELinux.set_mcs_label_R(@mcs_label, paths)
        end

        def set_ro_permission_R(*paths)
          PathUtils.oo_chown_R(0, @container.gid, paths)
          OpenShift::Runtime::Utils::SELinux.set_mcs_label_R(@mcs_label, paths)
        end

        def set_ro_permission(*paths)
          PathUtils.oo_chown(0, @container.gid, paths)
          OpenShift::Runtime::Utils::SELinux.set_mcs_label(@mcs_label, paths)
        end

        def set_rw_permission_R(*paths)
          PathUtils.oo_chown_R(@container.uid, @container.gid, paths)
          OpenShift::Runtime::Utils::SELinux.set_mcs_label_R(@mcs_label, paths)
        end

        def set_rw_permission(*paths)
          PathUtils.oo_chown(@container.uid, @container.gid, paths)
          OpenShift::Runtime::Utils::SELinux.set_mcs_label(@mcs_label, paths)
        end

        ##
        # Maps a given endpoint to the container IP and port where it is avaible.
        #
        # @param [Cartridge] cartridge the endpoint belongs to
        # @param [Endpoint] endpoint to map to ip and host
        # @return [String] Mapped endpoint in "IP:Port" format
        def map_cartridge_endpoint_ip_port(cartridge, endpoint)
          @container.list_proxy_mappings.each do |mapping|
            if endpoint.private_ip_name == mapping[:private_ip_name]
              return "#{get_nat_ip_address}:#{mapping[:proxy_port]}"
            end
          end
          raise Exception.new("Cartridge enpoint mapping not found")
        end

        private

        def set_default_route
          gw = @container_config.get('LIBVIRT_PRIVATE_IP_GW')
          out, _, _ = run_in_container_root_context(%{ip route show})
          m = out.match(/default via ([\d\.]+) dev eth0 \n/)
          if !m || m[1] != gw
            run_in_container_root_context(%{
              ip route del default;
              ip route add default via #{gw} dev eth0
            })
          end
        end

        def define_dummy_iface
          _, _, rc = run_in_container_root_context(%{ip link show dummy0})
          if rc != 0
            cmd = "ip link add dummy0 type dummy; "
            (1..127).each do |i|
              cmd += "ip addr add 169.254.169.#{i} dev dummy0; "
            end
            run_in_container_root_context(cmd)
          end
        end

        # Returns a Range representing the valid proxy port values
        def port_range
          uid_offset = @container.uid - @uid_begin
          proxy_port_begin = @port_begin + uid_offset * @ports_per_user

          proxy_port_range = (proxy_port_begin ... (proxy_port_begin + @ports_per_user))
          return proxy_port_range
        end

        def get_open_proxy_port
          endpoints = @container.list_proxy_mappings
          used_ports = endpoints.map{|entry| entry[:proxy_port]}
          port_range.each do |port|
            return port unless used_ports.include? port
          end
          nil
        end

        def reload_network
          set_default_route
          define_dummy_iface
          recreate_all_public_endpoints
        end

        def run_in_container_root_context(command, options = {})
          options[:unsetenv_others] = true
          options[:force_selinux_context] = false

          if options[:env].nil? or options[:env].empty?
            options[:env] = ::OpenShift::Runtime::Utils::Environ.for_gear(@container.container_dir)
          end

          if not File.exist?("/dev/container-id")
            command = "cd #{options[:chdir]} ; #{command}" if options[:chdir]
            command = "/usr/bin/virt-sandbox-service execute #{@container.uuid} -- /bin/bash -c '#{command}'"
            OpenShift::Runtime::Utils::oo_spawn(command, options)
          else
            OpenShift::Runtime::Utils::oo_spawn(command, options)
          end
        end

        # Private: list directories (cartridges) in home directory
        # @param  [String] home directory
        # @return [String] comma separated list of directories
        def list_home_dir(home_dir)
          results = []
          if File.exists?(home_dir)
            Dir.foreach(home_dir) do |entry|
              #next if entry =~ /^\.{1,2}/   # Ignore ".", "..", or hidden files
              results << entry
            end
          end
          results.join(', ')
        end

        def dotted_to_cidr(mask)
          IPAddr.new(mask, Socket::AF_INET).to_i.to_s(2).count('1')
        end

        def cidr_to_dotted(mask)
          IPAddr.new( ('1'*mask + '0'*(32-mask)).to_i(2), Socket::AF_INET).to_s
        end

        def get_nat_ip_address
          iprange = @container_config.get('LIBVIRT_PRIVATE_IP_RANGE')

          valid_ips = IPAddr.new(iprange).to_range
          uid_offset = @container.uid.to_i - @uid_begin
          gw_ip = @container_config.get('LIBVIRT_PRIVATE_IP_GW')

          #offset to skip address ending in .0
          nat_ip = valid_ips.first(uid_offset + 2).last.to_s
          if( nat_ip == gw_ip )
            nat_ip = valid_ips.first(uid_offset + 3).last.to_s
          end

          mask = iprange.split('/')[1]
          mask = dotted_to_cidr(mask) if mask.match('\.')

          nat_ip
        end

        def get_nat_ip_mask
          iprange = @container_config.get('LIBVIRT_PRIVATE_IP_RANGE')
          mask = iprange.split('/')[1]
          mask = dotted_to_cidr(mask) if mask.match('\.')

          mask
        end

        def create_iptables_rules(action, public_port, container_ip, node_ip, private_ip, private_port)
          if action == :add
            cmd = "iptables -t nat -A PREROUTING " +
                "-d #{container_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{private_ip}:#{private_port};" +
                "iptables -t nat -A OUTPUT " +
                "-d #{container_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{private_ip}:#{private_port};"
            run_in_container_root_context(cmd)

            cmd = "firewall-cmd --direct --passthrough ipv4 -t nat -A PREROUTING " +
                "-d #{node_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{container_ip}:#{public_port};" +
                "firewall-cmd --direct --passthrough ipv4 -t nat -A OUTPUT " +
                "-d #{node_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{container_ip}:#{public_port};" +
                "firewall-cmd --direct --passthrough ipv4 -t filter -I FORWARD " +
                "-p tcp --dport #{public_port} -d #{container_ip} -j ACCEPT"
            ::OpenShift::Runtime::Utils::oo_spawn(cmd)

            cmd = "firewall-cmd --permanent --direct --passthrough ipv4 -t nat -A PREROUTING " +
                "-d #{node_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{container_ip}:#{public_port};" +
                "firewall-cmd --permanent --direct --passthrough ipv4 -t nat -A OUTPUT " +
                "-d #{node_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{container_ip}:#{public_port};" +
                "firewall-cmd --permanent --direct --passthrough ipv4 -t filter -I FORWARD " +
                "-p tcp --dport #{public_port} -d #{container_ip} -j ACCEPT"
            ::OpenShift::Runtime::Utils::oo_spawn(cmd)
          end

          if action == :delete
            cmd = "iptables -t nat -D PREROUTING " +
                "-d #{container_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{private_ip}:#{private_port};" +
                "iptables -t nat -D OUTPUT " +
                "-d #{container_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{private_ip}:#{private_port};"
            run_in_container_root_context(cmd)

            cmd = "firewall-cmd --direct --passthrough ipv4 -t nat -D PREROUTING " +
                "-d #{node_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{container_ip}:#{public_port};" +
                "firewall-cmd --direct --passthrough ipv4 -t nat -D OUTPUT " +
                "-d #{node_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{container_ip}:#{public_port};" +
                "firewall-cmd --direct --passthrough ipv4 -t filter -D FORWARD " +
                "-p tcp --dport #{public_port} -d #{container_ip} -j ACCEPT"
            ::OpenShift::Runtime::Utils::oo_spawn(cmd)

            cmd = "firewall-cmd --permanent --direct --passthrough ipv4 -t nat -D PREROUTING " +
                "-d #{node_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{container_ip}:#{public_port};" +
                "firewall-cmd --permanent --direct --passthrough ipv4 -t nat -D OUTPUT " +
                "-d #{node_ip} -p tcp --dport=#{public_port} " +
                "-j DNAT --to-destination #{container_ip}:#{public_port};" +
                "firewall-cmd --permanent --direct --passthrough ipv4 -t filter -D FORWARD " +
                "-p tcp --dport #{public_port} -d #{container_ip} -j ACCEPT"
            ::OpenShift::Runtime::Utils::oo_spawn(cmd)
          end
        end

        def container_list
          out, _, _ = ::OpenShift::Runtime::Utils::oo_spawn("/usr/bin/virsh -c lxc:/// list --all")
          out.split("\n")[2..-1].map! do |m|
            m = m.split(" ")
            {
              name:  m[1],
              state: m[2..-1].join(" "),
            }
          end
        end

        def container_exists?
          return false unless File.exist?("/etc/libvirt-sandbox/services/#{@container.uuid}")
          container_list.each do |m|
            return true if m[:name] == @container.uuid
          end
          return false
        end

        def container_running?
          container_list.each do |m|
            return true if m[:name] == @container.uuid and m[:state] == "running"
          end
          return false
        end

        ##
        # Private: Delete and recreate all iptables/firewall rules for this container.
        # This is useful when restarting or restoring a LibVirt Sandbox based container.
        def recreate_all_public_endpoints
          proxy_mappings = @container.list_proxy_mappings
          delete_public_endpoints(proxy_mappings)
          proxy_mappings.each do |mapping|
            public_port  = mapping[:proxy_port]
            container_ip = get_nat_ip_address
            node_ip      = @config.get('PUBLIC_IP')
            private_ip   = mapping[:private_ip]
            private_port = mapping[:private_port]

            create_iptables_rules(:add, public_port, container_ip, node_ip, private_ip, private_port)
          end
        end
      end
    end
  end
end
