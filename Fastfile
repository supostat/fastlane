fastlane_version "2.53.1"
fastlane_require "semantic"
fastlane_require "semantic/core_ext"
fastlane_require "aws-sdk"
fastlane_require "byebug"
fastlane_require "dotenv"
require "./fastlane_helpers_instance"

environment = UI.select("Select your environment: ", [FastlaneHelpers::PRODUCTION_ENV, FastlaneHelpers::DEVELOPMENT_ENV])
env_variables = Dotenv.parse("../.env.fastlane.#{environment}")

fastlane_helpers_instance = FastlaneHelpers.new(
  env: environment,
  env_variables: env_variables,
)

fastlane_helpers_instance.check_wrong_keys_existence

Dotenv.load("../.env.fastlane.#{environment}")
Dotenv.require_keys(*FastlaneHelpers::REQUIRED_ENV_KEYS)

before_all do
  if environment == FastlaneHelpers::PRODUCTION_ENV
    ensure_git_branch(
      branch: master_branch
    )
  end

  ensure_git_status_clean
  fastlane_helpers_instance.git_fetch
  fastlane_helpers_instance.change_android_code_push_deployment_key(key: ENV["CODE_PUSH_ANDROID_DEPLOYMENT_KEY"])
  fastlane_helpers_instance.generate_frontend_env
end

lane :full_deploy do
  last_commit_hash = last_git_commit.fetch(:commit_hash)
  ios_app_url = nil
  android_app_url = nil
  begin
    new_version, tag_name = fastlane_helpers_instance.increment_major_version!

    if git_tag_exists(tag: tag_name)
      raise "Tag: #{tag_name} already exist."
    end
    update_ios_version!(version: new_version)
    fastlane_helpers_instance.update_android_version!(version: new_version)
    update_ios_deployment_data
    update_android_deployment_data
    fastlane_helpers_instance.git_add_and_commit_all(message: "Version Bump #{new_version}")
    begin
      add_git_tag(
        tag: tag_name,
      )
      push_git_tags(tag: tag_name)
      push_to_git_remote(
        force: false,
        force_with_lease: false,
        tags: false,
      )
      images_deploy
      ios_build
      s3_deploy_ios
      ios_app_url = Actions.lane_context[SharedValues::S3_HTML_OUTPUT_PATH]
      Actions.lane_context[SharedValues::IPA_OUTPUT_PATH] = nil
      Actions.lane_context[SharedValues::DSYM_OUTPUT_PATH] = nil
      android_build
      s3_deploy_android
      android_app_url = Actions.lane_context[SharedValues::S3_HTML_OUTPUT_PATH]
      Actions.lane_context[SharedValues::GRADLE_APK_OUTPUT_PATH] = nil
      ios_code_push_deploy
      android_code_push_deploy
      UI.success("Android app can be downloaded at '#{ios_app_url}'")
      UI.success("iOS app can be downloaded at '#{android_app_url}'")
    rescue SystemExit, Interrupt => ex
      puts "Task was stoped by CTRL+C"
      fastlane_helpers_instance.git_delete_tag(tag: tag_name)
      fastlane_helpers_instance.git_delete_tag_remote(tag: tag_name)
      raise ex
    rescue => ex
      fastlane_helpers_instance.git_delete_tag(tag: tag_name)
      fastlane_helpers_instance.git_delete_tag_remote(tag: tag_name)
      raise ex
    end
  rescue SystemExit, Interrupt => ex
    puts "Task was stoped by CTRL+C"
    fastlane_helpers_instance.git_reset_hard(hash: last_commit_hash)
    push_to_git_remote(
      force: false,
      force_with_lease: true,
      tags: false,
    )
    fastlane_helpers_instance.remove_frontend_env
    UI.error(ex.message)
  rescue => ex
    fastlane_helpers_instance.git_reset_hard(hash: last_commit_hash)
    push_to_git_remote(
      force: true,
      force_with_lease: false,
      tags: false,
    )
    fastlane_helpers_instance.remove_frontend_env
    UI.error(ex.message)
  end
end

lane :js_deploy do
  last_commit_hash = last_git_commit.fetch(:commit_hash)
  begin
    new_version, tag_name = fastlane_helpers_instance.increment_minor_version!
    if git_tag_exists(tag: tag_name)
      raise "Tag: #{tag_name} already exist."
    end
    update_ios_deployment_data
    update_android_deployment_data
    fastlane_helpers_instance.check_and_update_version_if_development(version: new_version)
    begin
      add_git_tag(
        tag: tag_name,
      )
      push_git_tags(tag: tag_name)
      push_to_git_remote(
        force: false,
        force_with_lease: true,
        tags: false,
      )
      ios_code_push_deploy
      android_code_push_deploy
    rescue => ex
      fastlane_helpers_instance.git_delete_tag(tag: tag_name)
      fastlane_helpers_instance.git_delete_tag_remote(tag: tag_name)
      raise ex
    end
  rescue => ex
    fastlane_helpers_instance.git_reset_hard(hash: last_commit_hash)
    push_to_git_remote(
      force: false,
      force_with_lease: true,
      tags: false,
    )
    fastlane_helpers_instance.remove_frontend_env
    UI.error(ex.message)
  end
end

lane :s3_deploy_ios do
  folder = ENV["S3_IMAGE_FOLDER"].empty? ? "" : ENV["S3_IMAGE_FOLDER"] + "/"
  aws_s3(
    access_key: ENV["S3_ACCESS_KEY"],
    secret_access_key: ENV["S3_SECRET_ACCESS_KEY"],
    bucket: ENV["S3_BUCKET"],
    region: ENV["S3_REGION"],
    app_directory: ENV["S3_IOS_APP_DIR"],
    html_template_path: "fastlane/s3_ios_html_template.erb",
    html_template_params: {
      base_img_url: "https://#{ENV["S3_IMAGE_BUCKET"]}.s3.#{ENV["S3_REGION"]}.amazonaws.com/#{folder}",
    },
  )
end
lane :s3_deploy_android do
  folder = ENV["S3_IMAGE_FOLDER"].empty? ? "" : ENV["S3_IMAGE_FOLDER"] + "/"
  aws_s3(
    access_key: ENV["S3_ACCESS_KEY"],
    secret_access_key: ENV["S3_SECRET_ACCESS_KEY"],
    bucket: ENV["S3_BUCKET"],
    region: ENV["S3_REGION"],
    app_directory: ENV["S3_ANDROID_APP_DIR"],
    html_template_path: "fastlane/s3_android_html_template.erb",
    html_template_params: {
      base_img_url: "https://#{ENV["S3_IMAGE_BUCKET"]}.s3.#{ENV["S3_REGION"]}.amazonaws.com/#{folder}",
    },
  )
end

desc "Deploy images for the app download pages"
private_lane :images_deploy do
  fastlane_helpers_instance.upload_files_to_s3
  UI.success("Files uploaded successful")
end

desc "Fetch certificates and provisioning profiles"
lane :certificates do
  match(app_identifier: ENV["IOS_APP_IDENTIFIER"], type: "enterprise", username: ENV["IOS_CERTIFICATE_USERNAME"], git_url: ENV["IOS_CERTIFICATE_REPOSITORY"])
end

private_lane :update_ios_deployment_data do
  provision_profile = "match InHouse #{ENV["IOS_APP_IDENTIFIER"]}"
  update_app_identifier(
    xcodeproj: ENV["IOS_PROJECT_FILE_PATH"],
    plist_path: ENV["IOS_PLIST_PATH"],
    app_identifier: ENV["IOS_APP_IDENTIFIER"],
  )
  update_info_plist(
    xcodeproj: ENV["IOS_PROJECT_FILE_PATH"],
    plist_path: ENV["IOS_PLIST_PATH"],
    block: proc do |plist|
      plist["CFBundleDisplayName"] = ENV["APP_NAME"]
      plist["CodePushDeploymentKey"] = ENV["CODE_PUSH_IOS_DEPLOYMENT_KEY"]
    end,
  )
  automatic_code_signing(
    path: ENV["IOS_PROJECT_FILE_PATH"],
    use_automatic_signing: false,
    profile_name: provision_profile,
  )
  fastlane_helpers_instance.update_ios_bundle_identifier(app_id: ENV["IOS_APP_IDENTIFIER"], xcodeproj_path: ENV["IOS_PROJECT_FILE_PATH"])
end

desc "Build the iOS application."
lane :ios_build do
  certificates
  gym(
    scheme: ENV["IOS_PROJECT_SCHEME"],
    project: ENV["IOS_PROJECT_FILE_PATH"],
    output_directory: "builds/",
    output_name: "#{ENV["IOS_APP_NAME"]}.ipa",
    silent: true,
  )
end

desc "Deploy to Code Push"
private_lane :ios_code_push_deploy do
  code_push_release_react(
    app_name: ENV["CODE_PUSH_IOS"],
    platform: "ios",
  )
end

desc "Deploy Android to Code Push"
private_lane :android_code_push_deploy do
  code_push_release_react(
    app_name: ENV["CODE_PUSH_ANDROID"],
    platform: "android",
  )
end

private_lane :update_android_deployment_data do
  set_value_in_build(
    app_project_dir: ENV["ANDROID_APP_PATH"],
    key: "applicationIdSuffix",
    value: ENV["ANDROID_APP_SUFFIX"],
  )
end

desc "Build the Android application."
lane :android_build do
  gradle(task: "clean", project_dir: ENV["ANDROID_PROJECT_FOLDER"])
  gradle(task: "assemble", build_type: "Release", project_dir: ENV["ANDROID_PROJECT_FOLDER"])
end
