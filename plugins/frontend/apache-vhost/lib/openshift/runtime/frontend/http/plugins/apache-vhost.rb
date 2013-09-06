#--
# Copyright 2013 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++

require 'rubygems'
require 'openshift-origin-frontend-apachedb'
require 'openshift-origin-node/model/frontend/http/plugins/frontend_http_base'
require 'openshift-origin-node/utils/shell_exec'
require 'openshift-origin-node/utils/node_logger'
require 'erb'
require 'json'
require 'fcntl'

$OpenShift_ApacheVirtualHosts_Lock = Mutex.new

module OpenShift
  module Runtime
    module Frontend
      module Http
        module Plugins

          class ApacheVirtualHosts < PluginBaseClass

            TEMPLATE_HTTP  = "/etc/httpd/conf.d/frontend-vhost-http-template.erb"
            TEMPLATE_HTTPS = "/etc/httpd/conf.d/frontend-vhost-https-template.erb"

            LOCK = $OpenShift_ApacheVirtualHosts_Lock
            LOCKFILE = "/var/run/openshift/apache-vhost.lock"

            attr_reader :basedir, :token, :app_path

            def initialize(container_uuid, fqdn, container_name, namespace)
              @config = ::OpenShift::Config.new
              @basedir = @config.get("OPENSHIFT_HTTP_CONF_DIR")

              @token = "#{@container_uuid}_#{@namespace}_#{@container_name}"
              @app_path = File.join(@basedir, token)

              @template_http  = TEMPLATE_HTTP
              @template_https = TEMPLATE_HTTPS

              super(container_uuid, fqdn, container_name, namespace)
            end


            def conf_path
              @app_path + ".conf"
            end

            def element_path_prefix
              "555555_element-"
            end

            def parse_connection(element_file)
              path, uri, options = [ "", "", {} ]
              File.open(element_file, File::RDONLY) do |f|
                f.each do |l|
                  if l =~ /^\# ELEMENT: (.*)$/
                    path, uri, options = JSON.load($~[1])
                  end
                end
              end
              [ path, uri, options ]
            end

            def element_path(path)
              tpath = path.gsub('/','_')
              File.join(@app_path,"#{element_path_prefix}#{tpath}")
            end

            def create
              FileUtils.mkdir_p(@app_path)
            end

            def destroy
              with_lock_and_reload do
                FileUtils.rm_rf(Dir.glob(File.join(@basedir, "#{container_uuid}_*")))
              end
            end

            def connect(*elements)
              with_lock_and_reload do

                # The base config won't exist until the first connection is created
                if not File.exists?(conf_path)
                  File.open(conf_path, File::RDWR | File::CREAT | File::TRUNC) do |f|
                    server_name = @fqdn
                    include_path = @app_path
                    ssl_certificate_file = '/etc/pki/tls/certs/localhost.crt'
                    ssl_key_file = '/etc/pki/tls/private/localhost.key'
                    f.write(ERB.new(File.read(@template_http)).result(binding))
                    f.write("\n")
                    f.write(ERB.new(File.read(@template_https)).result(binding))
                    f.write("\n")
                    f.fsync
                  end
                end

                # Process target_update option by loading the old values
                elements.each do |path, uri, options|
                  if options["target_update"]
                    begin
                      options = parse_connection(element_path(path))[2]
                    rescue Errno::EONENT
                      raise PluginException.new("The target_update option specified but no old configuration: #{path}",
                                                @container_uuid, @fqdn)
                    rescue JSON::ParserError, NoMethodError
                      raise PluginException.new("The target_update option specified but old config could not be parsed: #{path}",
                                                @container_uuid, @fqdn)
                    end
                  end

                  File.open(element_path(path), File::RDWR | File::CREAT | File::TRUNC) do |f|
                    f.write("# ELEMENT: ")
                    f.write([path, uri, options].to_json)
                    f.write("\n")
                    
                    path="/#{path}" unless path.start_with?("/")
                    uri="/#{uri}" unless uri.start_with?("/")

                    if options["gone"]
                      f.puts("RewriteRule ^#{path}(/.*)?$ - [NS,G]")
                    elsif options["forbidden"]
                      f.puts("RewriteRule ^#{path}(/.*)?$ - [NS,F]")
                    elsif options["noproxy"]
                      f.puts("RewriteRule ^#{path}(/.*)?$ - [NS,L]")
                    elsif options["health"]
                      f.puts("RewriteRule ^#{path}(/.*)?$ /var/www/html/health.txt [NS,L]")
                    elsif options["redirect"]
                      f.puts("RewriteRule ^#{path}(/.*)?$ #{uri} [R,NS,L]")
                    elsif options["file"]
                      f.puts("RewriteRule ^#{path}(/.*)?$ #{uri} [NS,L]")
                    elsif options["tohttps"]
                      f.puts("RewriteCond %{HTTPS} =off")
                      f.puts("RewriteRule ^#{path}(/.*)?$ https://%{HTTP_HOST}$1 [R,NS,L]")
                    else
                      f.puts("RewriteRule ^#{path}(/.*)?$ http://#{uri}$1 [P,NS]")
                      f.puts("ProxyPassReverse #{path} http://#{uri}")
                    end

                    f.fsync
                  end
                end
              end
            end

            def connections
              Dir.glob(element_path('*')).map do |p|
                parse_connections(p)
              end
            end

            def disconnect(*paths)
              with_lock_and_reload do
                paths.flatten.each do |p|
                  FileUtils.rm_f(element_path(path))
                end
              end
            end



            def idle_path_prefix
              "000000_idler"
            end

            def idle_path
              File.join(@app_path, "#{idle_path_prefix}.conf")
            end

            def idle
              with_lock_and_reload do
                File.open(idle_path, File::RDWR | File::CREAT | File::TRUNC ) do |f|
                  f.puts("RewriteRule ^/(.*)$ /var/www/html/restorer.php/#{@container_uuid}/$1 [NS,L]")
                end
              end
            end

            def unidle
              with_lock_and_reload do
                FileUtils.rm_f(idle_path)
              end
            end

            def idle?
              File.exists?(idle_path)
            end




            def sts_path_prefix(max_age)
              "000001_sts_header-"
            end

            def sts_path(max_age)
              File.join(@app_path, "#{sts_path_prefix}#{max_age}.conf")
            end

            def sts(max_age=15768000)
              with_lock_and_reload do
                Dir.glob(sts_path('*')).each do |p|
                  FileUtils.rm_f(p)
                end              
                File.open(sts_path(max_age), File::RDWR | File::CREAT | File::TRUNC ) do |f|
                  f.puts("Header set Strict-Transport-Security \"max-age=#{max_age.to_i}\"")
                  f.puts("RewriteCond %{HTTPS} =off")
                  f.puts("RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R,NS,L]")
                end
              end
            end

            def no_sts
              with_lock_and_reload do
                Dir.glob(sts_path('*')).each do |p|
                  FileUtils.rm_f(p)
                end
              end
            end

            def get_sts
              Dir.glob(sts_path('*')).each do |f|
                return File.basename(f,".conf").gsub(sts_path_prefix,'')
              end
              nil
            end



            def alias_path_prefix
              "888888_server_alias-"
            end

            def alias_path(server_alias)
              File.join(@app_path, "#{alias_path_prefix}#{server_alias}.conf")
            end

            def aliases
              Dir.glob(alias_path('*')).map { |f|
                File.basename(f,".conf").gsub(alias_path_prefix,'')
              }
            end

            def add_alias(server_alias)
              with_lock_and_reload do
                File.open(alias_path(server_alias), File::RDWR | File::CREAT | File::TRUNC ) do |f|
                  f.puts("ServerAlias #{server_alias}")
                  f.fsync
                end
              end
            end

            def remove_alias(server_alias)
              with_lock_and_reload do
                FileUtils.rm_f(alias_path(server_alias))
                remove_ssl_cert_impl(server_alias)
              end
            end



            def ssl_conf_path(server_alias)
              File.join(@basedir, server_alias + ".conf")
            end

            def ssl_certiticate_path(server_alias)
              File.join(@app_path, server_alias + ".crt")
            end

            def ssl_key_path(server_alias)
              File.join(@app_path, server_alias + ".key")
            end


            def ssl_certs
              aliases.map { |server_alias|
                begin
                  ssl_cert = File.read(ssl_certiticate_path(server_alias))
                  priv_key = File.read(ssl_key_path(server_alias))
                rescue Errno::ENOENT
                end
                [ ssl_cert, priv_key, server_alias ]
              }.select { |ssl_cert, priv_key, server_alias|
                ssl_cert.to_s != ""
              }
            end

            def add_ssl_cert(ssl_cert, priv_key, server_alias)
              with_lock_and_reload do
                if not File.exists?(alias_path(server_alias))
                  raise PluginException.new("Specified alias #{server_alias} does not exist for the app",
                                            @container_uuid, @fqdn)
                end

                ssl_certificate_file = ssl_certificate_path(server_alias)
                ssl_key_file = ssl_key_path(server_alias)

                file.open(ssl_certificate_file, File::RDWR | File::CREAT | File::TRUNC) do |f|
                  f.write(ssl_cert)
                  f.fsync
                end

                file.open(ssl_key_file, File::RDWR | File::CREAT | File::TRUNC) do |f|
                  f.write(priv_key)
                  f.fsync
                end

                File.open(ssl_conf_path, File::RDWR | File::CREAT | File::TRUNC) do |f|
                  server_name = server_alias
                  include_path = @app_path
                  f.write(ERB.new(File.read(@template_https)).result)
                  f.write("\n")
                  f.fsync
                end
              end
            end

            def remove_ssl_cert_impl(server_alias)
              FileUtils.rm_f(ssl_conf_path(server_alias))
              FileUtils.rm_f(ssl_certiticate_path(server_alias))
              FileUtils.rm_f(ssl_key_path(server_alias))
            end

            def remove_ssl_cert(server_alias)
              with_lock_and_reload do
                remove_ssl_cert_impl(server_alias)
              end
            end

            # Private: Lock and reload changes to Apache
            def with_lock_and_reload
              LOCK.synchronize do
                File.open(LOCKFILE, File::RDWR | File::CREAT | File::TRUNC | File::SYNC , 0640) do |f|
                  f.sync = true
                  f.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)
                  f.flock(File::LOCK_EX)
                  f.write(Process.pid)
                  begin
                    yield
                  ensure
                    f.flock(File::LOCK_UN)
                  end
                end
              end
              ::OpenShift::Runtime::Frontend::Http::Plugins::reload_httpd
            end

          end

        end
      end
    end
  end
end
