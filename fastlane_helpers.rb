require "fastlane/action"
require "fastlane"
require "aws-sdk"
require "byebug"
require "nokogiri"

GIT_LS_LINE_FORMAT = /^[0-9a-f]{40}\trefs\/tags\/\S+$/
GIT_LS_TAG_NAME_CAPTURE_REGEX = /^[0-9a-f]{40}\trefs\/tags\/(\S+)$/
PRODUCTION_VERSION_TAG_NAME = /^\d{0,3}\.\d{0,3}\.\d{0,3}$/
DEVELOPMENT_VERSION_TAG_NAME_REGEX = /^development-\d{0,3}\.\d{0,3}\.\d{0,3}$/

def update_ios_version!(version:)
  Fastlane::Actions::IncrementVersionNumberAction.run({
    version_number: version.to_s,
    xcodeproj: "../#{ENV["IOS_PROJECT_FILE_PATH"]}",
  })
end

def get_ios_version
  Fastlane::Actions::GetVersionNumberAction.run({xcodeproj: "../#{ENV["IOS_PROJECT_FILE_PATH"]}"}).to_version
end

class FastlaneHelpers
  PRODUCTION_ENV = "production"
  DEVELOPMENT_ENV = "development"
  MASTER_BRANCH = "master"
  FRONTEND_ENV_PATH = "../.env"
  FRONTEND_ENV_KEYS = [
    "APP_SENTRY_LINK",
    "APP_IOS_DOWNLOAD_URL",
    "APP_ANDROID_DOWNLOAD_URL",
    "APP_LAMBDA_BASE_URL",
    "APP_BASE_URL",
  ].freeze
  DEPLOYMENT_ENV_KEYS = [
    "IOS_PROJECT_FOLDER",
    "ANDROID_PROJECT_FOLDER",
    "IOS_APP_NAME",
    "IOS_PROJECT_FILE_PATH",
    "IOS_APP_IDENTIFIER",
    "IOS_PROJECT_SCHEME",
    "CODE_PUSH_IOS",
    "CODE_PUSH_ANDROID",
    "S3_ACCESS_KEY",
    "S3_SECRET_ACCESS_KEY",
    "S3_BUCKET",
    "S3_REGION",
    "S3_IMAGE_BUCKET",
    "S3_IMAGE_FOLDER",
    "S3_IOS_APP_DIR",
    "S3_ANDROID_APP_DIR",
    "IOS_PLIST_PATH",
    "ANDROID_BUILD_GRADLE_PATH",
    "APP_NAME",
    "ANDROID_APP_PATH",
    "ANDROID_APP_SUFFIX",
    "CODE_PUSH_ANDROID_DEPLOYMENT_KEY",
    "CODE_PUSH_IOS_DEPLOYMENT_KEY",
    "IOS_CERTIFICATE_REPOSITORY",
    "IOS_CERTIFICATE_USERNAME",
  ].freeze

  REQUIRED_ENV_KEYS = (FastlaneHelpers::DEPLOYMENT_ENV_KEYS + FastlaneHelpers::FRONTEND_ENV_KEYS).freeze

  def initialize(env:, env_variables:)
    @env = env
    @env_variables = env_variables
  end

  def check_wrong_keys_existence
    supplied_keys = env_variables.keys
    required_keys = FastlaneHelpers::REQUIRED_ENV_KEYS

    if (!supplied_keys.all? {|key| required_keys.include?(key) })
      unsupported_keys = supplied_keys.select {|key| !required_keys.include?(key)}
      raise "Invalid vars supplied, #{unsupported_keys.join(", ")}"
    end
  end

  def generate_frontend_env
    # Ensure fresh file
    remove_frontend_env

    temp_env_file = File.new(FRONTEND_ENV_PATH, "w")
    frontend_keys = FastlaneHelpers::FRONTEND_ENV_KEYS
    frontend_variables = env_variables.select {|(key, value)| frontend_keys.include?(key) }
    frontend_variables.each do |(key, value)|
      temp_env_file.puts("#{key}=\"#{value}\"")
    end
    temp_env_file.close
  end

  def remove_frontend_env
    File.delete(FRONTEND_ENV_PATH) if File.exist?(FRONTEND_ENV_PATH)
  end

  def upload_file_to_s3(file_path:)
    Aws.config.update({
      region: ENV["S3_REGION"],
      credentials: Aws::Credentials.new(ENV["S3_ACCESS_KEY"], ENV["S3_SECRET_ACCESS_KEY"]),
    })

    file_data = File.open(file_path, "rb")
    s3_client = Aws::S3::Client.new
    bucket = Aws::S3::Bucket.new(ENV["S3_IMAGE_BUCKET"], client: s3_client)
    base_file_name = File.basename(file_path)
    folder = !ENV["S3_IMAGE_FOLDER"].empty? ? "#{ENV["S3_IMAGE_FOLDER"]}/" : ""

    details = {
      acl: "public-read",
      key: folder + base_file_name,
      body: file_data,
    }
    obj = bucket.put_object(details)
    if obj.kind_of? Aws::S3::ObjectVersion
      obj = obj.object
    end
    pp "Uploaded #{obj.public_url.to_s}"
  end

  def upload_files_to_s3
    pp "Uploading images to S3 ..."
    files = Dir["./images/*"]
    files.each do |file_path|
      upload_file_to_s3(file_path: file_path)
    end
  end

  def update_android_version!(version:)
    path = "../android/app/build.gradle"
    re = /versionName\s+"(.*)"/

    build_file = File.read(path)
    build_file[re, 1] = version.to_s

    f = File.new(path, "w")
    f.write(build_file)
    f.close
  end

  def update_ios_bundle_identifier(app_id:, xcodeproj_path:)
    path = "../#{xcodeproj_path}/project.pbxproj"
    p = File.read(path)
    p.gsub!(/PRODUCT_BUNDLE_IDENTIFIER = .*;/, "PRODUCT_BUNDLE_IDENTIFIER = #{app_id};")
    File.write(path, p)
  end

  def git_reset_hard(hash:)
    Fastlane::Action.sh "git", "reset", "--hard", hash
  end

  def remote_version_tags
    result = Fastlane::Action.sh "git", "ls-remote", "--tags", "--refs", "origin" do |status, result, command|
      unless status.success?
        raise "Command #{command} (pid #{status.pid}) failed with status #{status.exitstatus}"
      end
      lines = result.split("\n")

      # validate format
      lines.each_with_index do |line, index|
        if !(line =~ GIT_LS_LINE_FORMAT)
          raise "Invalid format of git ls-remote at line #{index}\nline: #{line}"
        end
      end

      #extract tag names
      tag_names = lines.map do |line|
        line.match(GIT_LS_TAG_NAME_CAPTURE_REGEX)[1]
      end

      tag_names
    end
  end

  def extract_production_version_numbers(tag_names:)
    tag_names.
      select{ |tag_name| tag_name =~ PRODUCTION_VERSION_TAG_NAME }.
      map(&:to_version)
  end

  def extract_development_version_numbers(tag_names:)
    tag_names.
      select{ |tag_name| tag_name =~ DEVELOPMENT_VERSION_TAG_NAME_REGEX }.
      map{ |tag_name| tag_name.gsub('development-', '').to_version }
  end

  def git_delete_tag(tag:)
    Fastlane::Action.sh "git", "tag", "-d", tag
  end

  def git_delete_tag_remote(tag:)
    Fastlane::Action.sh "git", "push", "-d", "origin", tag
  end

  def git_fetch
    Fastlane::Action.sh "git", "fetch"
  end

  def get_current_version_from_remote
    all_tag_names = remote_version_tags
    version_numbers = nil

    case env
    when PRODUCTION_ENV
      version_numbers = extract_production_version_numbers(tag_names: all_tag_names)
    when DEVELOPMENT_ENV
      version_numbers = extract_development_version_numbers(tag_names: all_tag_names)
    else
      raise "Unknown environment"
    end

    if version_numbers.length === 0
      version_numbers = ["0.0.1"].to_version
    end

    version_numbers.sort { |x, y| x <=> y }.last
  end

  def increment_major_version!
    current_version = get_current_version_from_remote
    new_version = current_version.major!
    write_new_version!(new_version: new_version)
  end

  def increment_minor_version!
    current_version = get_current_version_from_remote
    new_version = current_version.minor!
    write_new_version!(new_version: new_version)
  end

  def write_new_version!(new_version:)
    case env
    when PRODUCTION_ENV
      write_package_json_version!(version: new_version)
      tag_name = new_version
      [new_version, tag_name.to_string]
    when DEVELOPMENT_ENV
      # do nothing, just return new version and tag name, we are using git tags to store development versions
      tag_name = "development-#{new_version}"
      [new_version, tag_name]
    else
      raise "Unknown environment"
    end
  end

  def change_android_code_push_deployment_key(key:)
    path = "../#{ENV["ANDROID_APP_PATH"]}/src/main/res/values/strings.xml"
    doc = File.open(path, "r:UTF-8") do |f|
      @doc = Nokogiri::XML(f)
      originalName = nil
      @doc.css("resources string[@name=reactNativeCodePush_androidDeploymentKey]").each do |response_node|
        originalName = response_node.content
        response_node.content = key
        Fastlane::UI.message("Updating codepush deployment key to: #{key}")
      end

      File.write(path, @doc.to_xml(encoding: "UTF-8"))
    end
  end

  def check_and_update_version_if_development(version:)
    ios_version = get_ios_version
    android_version = get_android_version
    if ios_version != android_version
      raise "iOS and Android versions should match"
    end
    if ios_version.major != version.major
      binary_version = "#{version.major}.0.0".to_version
      update_ios_version!(version: binary_version)
      update_android_version!(version: binary_version)
    end
    git_add_and_commit_all(message: "Version Bump (v#{version})")
  end

  def git_status_clean?
    repo_status = Fastlane::Actions.sh("git status --porcelain")
    repo_status.empty?
  end

  def git_add_and_commit_all(message:)
    unless git_status_clean?
      staged_files = Fastlane::Action.sh("git", "add", "-A")
      Fastlane::Action.sh("git", "commit", "-m", message)
    end
  end

  private
  attr_reader :env, :env_variables

  def get_package_json
    file = File.read("../package.json")
    JSON.parse(file)
  end

  def write_package_json!(json:)
    File.open("../package.json", "w") { |f| f.write JSON.pretty_generate(json) }
  end

  def write_package_json_version!(version:)
    package_json = get_package_json
    package_json["version"] = version.to_s
    write_package_json!(json: package_json)
  end

  def read_package_json_version
    package_json = get_package_json
    package_json["version"].to_version
  end

  def increment_package_json_minor_version!
    current_version = read_package_json_version
    new_version = current_version.minor!
    write_package_json_version!(version: new_version)
    new_version
  end

  def increment_package_json_major_version!
    current_version = read_package_json_version
    new_version = current_version.major!
    write_package_json_version!(version: new_version)
    new_version
  end

  def increment_package_json_patch_version!
    current_version = read_package_json_version
    new_version = current_version.patch!
    write_package_json_version!(version: new_version)
    new_version
  end

  def get_android_version
    path = "../android/app/build.gradle"
    re = /versionName\s+"(.*)"/

    build_file = File.read(path)
    build_file[re, 1].to_version
  end
end
