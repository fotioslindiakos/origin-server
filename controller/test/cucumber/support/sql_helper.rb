module SQLHelper
  def send_sql_file(statement)
    # This allows us to cache the sent statements
    @sent_files ||= {}
    @sent_files[statement] ||= (
      tmpfile = Tempfile.new('sql')
      File.open(tmpfile,'w') do |f|
        f.write(statement)
      end
      tmpfile.close
      path = @app.scp_file(tmpfile.path)
      tmpfile.unlink
      path
    )
  end

  # Create a string of exports from the env variables
  def env_vars_string(clear_vars, keep_vars = {})
    vars = clear_vars.inject({}) do |hash,val|
      hash[val] = ''
      hash
    end
    vars.merge!(keep_vars)
    vars.delete_if{|_,v| v.nil? }
    vars.inject(""){|str,(key,val)| "#{str} export #{key}=#{val};"}.strip
  end

  def run_psql(statement, opts = {}, env = {}, use_helper = true)
    default_opts = {
      '-t' => '',
      '-w' => ''
    }

    # Determine whether to use the helper wrapper function
    cmd = use_helper ? "psql" : "/usr/bin/psql"

    # SCP the file so we don't have to worry about escaping SQL
    if @app.respond_to?(:scp_file)
      opts['-f'] = send_sql_file(statement)
    else
      cmd = "echo '#{statement}' | #{cmd}"
    end

    # Don't touch the variables if we're using the helper
    unless use_helper
      # These vars will be set to an empty string unless overridden
      clear_vars = %w(PGPASSFILE PGUSER PGHOST PGDATABASE PGDATA)
      # Prepend the export statements to the command
      cmd = "%s #{cmd}" % env_vars_string(clear_vars, env)
      # Need to specify the database when not using the helper
      default_opts['-d'] = '$OPENSHIFT_APP_NAME'
    end

    # Add out default opts
    opts = default_opts.merge(opts)
    # Remove any nil opts (but leave empty string)
    opts.delete_if{|k,v| v.nil? }
    # Turn opts into '-k val' format
    opts = opts.inject(""){|str,(key,val)| "#{str} #{key} #{val}" }.strip

    cmd = "-o LogLevel=quiet \"#{cmd} #{opts} 2>/dev/null\""
    cmd.gsub!(/\$/,'\\$')

    if @app && @app.respond_to?(:ssh_command)
      @app.ssh_command(cmd)
    else
      cmd = ssh_command(cmd)
      $logger.debug "Running #{cmd}"

      output = `#{cmd}`

      $logger.debug "Output: #{output}"
      output.strip
    end
  end
end

World(SQLHelper)
