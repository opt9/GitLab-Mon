#!/usr/bin/env ruby

require 'digest'
require 'base64'
require 'openssl'
require 'cgi'
require 'uri'
require 'net/https'
require 'net/smtp'
require 'json'
require 'yaml'
require 'csv'
require 'fileutils'


class GitlabList

  def initialize
    @conf = YAML.load_file(File.join(__dir__, 'config.yml'))
    STDERR.puts "GitLab repo: #{@conf['GITLAB_URL']}"
    FileUtils.rm @conf['ADD'], :force => true
    FileUtils.rm @conf['DEL'], :force => true
    FileUtils.rm @conf['OLD'], :force => true
    FileUtils.rm @conf['NEW'], :force => true
  end

  # Get repositories from GitLab
  def get_new_repo
    # Loads all projects into local file. Page by page, 100 entries each
    recache_gitlab_projects = lambda {
      STDERR.puts 'Loading project list from GitLab to local project file'

      projects = []
      i = 0
      until (part = `curl "#{@conf['GITLAB_URL']}/api/v3/projects/all?page=#{i += 1}&per_page=100&private_token=#{@conf['PRIVATE_TOKEN']}"`).eql? '[]'
        STDERR.puts "Adding #{i}th 100 entries"
        projects << JSON.parse(part).flatten
      end
      File.open(@conf['PRJ'], 'w') { |file| file.write(JSON.generate(projects.flatten)) }
    }

    # Get repos
    list_up = lambda {
      projects = File.read(@conf['PRJ'])
      JSON.parse(projects).each do |el|
        # Get 'release' version only
        #next unless 'release'.eql?(el['namespace']['name'])
        list = [el['path_with_namespace'], 'git', el['http_url_to_repo'], "#{@conf['GITLAB_ID']}", "#{@conf['GITLAB_PW']}", el['web_url'], el['default_branch'] ||= 'master'].join(',')
        File.open(@conf['NEW'], 'a+') { |file| file.puts(list) }
      end
    }

    recache_gitlab_projects[]
    list_up[]
  end

  # Diff searchcode-server repos and gitlab repos
  def get_diff
    old = IO.readlines(@conf['OLD']).map(&:chomp)
    new = IO.readlines(@conf['NEW']).map(&:chomp)

    File.open(@conf['ADD'], 'w') { |file| file.write((new-old).join("\n")) }
    File.open(@conf['DEL'], 'w') { |file| file.write((old-new).join("\n")) }
  end

  # Send web request
  def send_request(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)

    req = Net::HTTP::Get.new uri
    res = http.request req
    data = JSON.parse(res.body)
  end

  # HMAC
  def sign(privatekey, message, algorithm)
    return OpenSSL::HMAC.hexdigest(algorithm, privatekey, message)
  end

  # Add repository and send report
  def add_repo
    File.open(@conf['ADD'], 'r').each do |line|
      STDERR.puts("ADD")
      STDERR.puts(line)
      add_request(line)
      send_mail(line, 'Added')
    end
  end

  # Add repository (API request)
  def add_request(repo)
    CSV.parse(repo) do |row|
      reponame, repotype, repourl, repousername, repopassword, reposource, repobranch = row

      message = 'pub=%s&reponame=%s&repourl=%s&repotype=%s&repousername=%s&repopassword=%s&reposource=%s&repobranch=%s' % [
        CGI::escape(@conf['PUBLIC_KEY']),
        CGI::escape(reponame),
        CGI::escape(repourl),
        CGI::escape(repotype),
        CGI::escape(repousername),
        CGI::escape(repopassword),
        CGI::escape(reposource),
        CGI::escape(repobranch),
      ]

      sig = sign(@conf['PRIVATE_KEY'], message, OpenSSL::Digest.new(@conf['ALGORITHM']))
      url = "#{@conf['API_URL']}/add/?sig=%s&%s" % [ CGI::escape(sig), message ]
      ret = send_request(url)
      puts ret
    end
  end

  # Delete repository and send report
  def del_repo
    File.open(@conf['DEL'], 'r').each do |line|
      STDERR.puts("DEL")
      STDERR.puts(line)
      del_request(line)
      send_mail(line, 'Deleted')
    end
  end

  # Delete repository (API request)
  def del_request(repo)
    CSV.parse(repo) do |row|
      reponame, repotype, repourl, repousername, repopassword, reposource, repobranch = row

      message = 'pub=%s&reponame=%s' % [
        CGI::escape(@conf['PUBLIC_KEY']),
        CGI::escape(reponame),
      ]

      sig = sign(@conf['PRIVATE_KEY'], message, OpenSSL::Digest.new(@conf['ALGORITHM']))
      url = "#{@conf['API_URL']}/delete/?sig=%s&%s" % [ CGI::escape(sig), message ]
      ret = send_request(url)
      puts ret
    end
  end

  # Get repository list from Searchcode-server (API request)
  def get_old_repo
    message = 'pub=%s' % [
      CGI::escape(@conf['PUBLIC_KEY']),
    ]

    sig = sign(@conf['PRIVATE_KEY'], message, OpenSSL::Digest.new(@conf['ALGORITHM']))
    url = "#{@conf['API_URL']}/list/?sig=%s&%s" % [ CGI::escape(sig), message ]
    data = send_request(url)

    data['repoResultList'].each do |repo|
      # name, scm, url, username, password, source, branch
      list = "#{repo['name']},#{repo['scm']},#{repo['url']},#{repo['username']},#{repo['password']},#{repo['source']},#{repo['branch']}"
      File.open(@conf['OLD'], 'a+') { |file| file.puts(list) }
    end
  end

  # Recrawl & Rebuild Indexes (API request)
  def reindex
    message = 'pub=%s' % [
      CGI::escape(@conf['PUBLIC_KEY']),
    ]

    sig = sign(@conf['PRIVATE_KEY'], message, OpenSSL::Digest.new(@conf['ALGORITHM']))
    url = "#{@conf['API_URL']}/reindex/?sig=%s&%s" % [ CGI::escape(sig), message ]
    ret = send_request(url)
    puts ret
  end

  # Send report mail to admins
  def send_mail(repo, action)
    CSV.parse(repo) do |row|
      reponame, repotype, repourl, repousername, repopassword, reposource, repobranch = row
      message = <<MESSAGE_END
From: #{@conf['SNAME']} <#{@conf['SENDER']}>
To: #{@conf['RNAME']} <#{@conf['RECEIVER']}>
MIME-Version: 1.0
Content-type: text/html
Subject: [#{@conf['SNAME']}] #{action}: #{reponame}

<h2>GitLab Notice</h2>
 #{action} <b>"#{reponame}"</b>: <a href="#{reposource}">#{reposource}</a><br /><br />

If you have any question about this email, please contact me.<br />
 #{@conf['SIGNATURE']}
MESSAGE_END

      Net::SMTP.start(@conf['MAILSVR']) do |smtp|
        smtp.send_message message, "#{@conf['SENDER']}","#{@conf['RECEIVER']}"
      end

    end
  end

  def main
    get_old_repo
    get_new_repo
    get_diff
    del_repo
    add_repo
    reindex
  end

end

exit -1 unless GitlabList.new.main
