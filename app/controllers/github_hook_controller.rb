require 'json'

class GithubHookController < ApplicationController

  GIT_BIN = Redmine::Configuration['scm_git_command'] || "git"
  skip_before_filter :verify_authenticity_token, :check_if_login_required

  def index
    if request.post?
      repositories = find_repositories

      repositories.each do |repository|
        # Fetch the changes from Github
        update_repository(repository)

        # Fetch the new changesets into Redmine
        repository.fetch_changesets
      end
    end

    render(:text => 'OK')
  end

  def welcome
    # Render the default layout
  end

  private

  def system(command)
    Kernel.system(command)
  end

  # Executes shell command. Returns true if the shell command exits with a
  # success status code.
  #
  # If directory is given the current directory will be changed to that
  # directory before executing command.
  def exec(command, directory)
    logger.debug { "GithubHook: Executing command: '#{command}'" }

    # Get a path to a temp file
    logfile = Tempfile.new('github_hook_exec')
    logfile.close

    full_command = "#{command} > #{logfile.path} 2>&1"
    success = if directory.present?
      Dir.chdir(directory) do
        system(full_command)
      end
    else
      system(full_command)
    end

    output_from_command = File.readlines(logfile.path)
    if success
      logger.debug { "GithubHook: Command output: #{output_from_command.inspect}"}
    else
      logger.error { "GithubHook: Command '#{command}' didn't exit properly. Full output: #{output_from_command.inspect}"}
    end

    return success
  ensure
    logfile.unlink
  end

  def git_command(command)
    GIT_BIN + " #{command}"
  end

  # Fetches updates from the remote repository
  def update_repository(repository)
    command = git_command('fetch origin')
    if exec(command, repository.url)
      command = git_command("fetch origin \"+refs/heads/*:refs/heads/*\"")
      exec(command, repository.url)
    end
  end

  # Gets the project identifier from the querystring parameters and if that's not supplied, assume
  # the Github repository name is the same as the project identifier.
  def get_identifier
    identifier = get_project_name
    raise ActiveRecord::RecordNotFound, "Project identifier not specified" if identifier.nil?
    return identifier
  end

  # Attempts to find the project name. It first looks in the params, then in the
  # payload if params[:project_id] isn't given.
  def get_project_name
    payload = JSON.parse(params[:payload] || '{}')
    params[:project_id] || (payload['repository'] ? payload['repository']['name'] : nil)
  end

  # Finds the Redmine project in the database based on the given project identifier
  def find_project
    identifier = get_identifier
    project = Project.find_by_identifier(identifier.downcase)
    raise ActiveRecord::RecordNotFound, "No project found with identifier '#{identifier}'" if project.nil?
    return project
  end

  # Returns the Redmine Repository object we are trying to update
  def find_repositories
    project = find_project
    repositories = project.repositories.select do |repo|
      repo.is_a?(Repository::Git)
    end

    if repositories.nil? or repositories.length == 0
      raise TypeError, "Project '#{project.to_s}' ('#{project.identifier}') has no repository"
    end

    return repositories
  end

end
