# To implement fastlane to your project, need to make these steps below:

1. Link submodule to the project
```
$> git submodule add <giturl> fastlane
```
2. Copy `.env.fastlane.example` to the project root
3. Change `.env.fastlane.example` file name suffix to one of (.production or .development) and fill in the variables.
