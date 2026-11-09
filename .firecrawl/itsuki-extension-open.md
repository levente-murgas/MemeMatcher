[Sitemap](https://medium.com/sitemap/sitemap.xml)

[Open in app](https://play.google.com/store/apps/details?id=com.medium.reader&referrer=utm_source%3DmobileNavBar&source=---top_nav_layout_nav-----------------------------------------)

Sign up

[Sign in](https://medium.com/m/signin?operation=login&redirect=https%3A%2F%2Fmedium.com%2F%40itsuki.enjoy%2Fswift-when-extensioncontext-open-does-not-open-my-app-solution-eaf59ab552c2&source=post_page---top_nav_layout_nav-----------------------global_nav------------------)

[Medium Logo](https://medium.com/?source=---top_nav_layout_nav-----------------------------------------)

Get app

[Write](https://medium.com/m/signin?operation=register&redirect=https%3A%2F%2Fmedium.com%2Fnew-story&source=---top_nav_layout_nav-----------------------new_post_topnav------------------)

[Search](https://medium.com/search?source=---top_nav_layout_nav-----------------------------------------)

Sign up

[Sign in](https://medium.com/m/signin?operation=login&redirect=https%3A%2F%2Fmedium.com%2F%40itsuki.enjoy%2Fswift-when-extensioncontext-open-does-not-open-my-app-solution-eaf59ab552c2&source=post_page---top_nav_layout_nav-----------------------global_nav------------------)

![Unknown user](https://miro.medium.com/v2/resize:fill:32:32/1*dmbNkD5D-u45r44go_cf0g.png)

1. [Problem Statement](https://medium.com/?source=-----eaf59ab552c2---------------------------------------#c175 "Problem Statement")
2. [Solution](https://medium.com/?source=-----eaf59ab552c2---------------------------------------#15dd "Solution")

Swift

IOS App Development

IOS Development

# Swift: When ExtensionContext.Open Does NOT Open My App! + Solution!

## All I want is to open up my App from my extension!

[![Itsuki](https://miro.medium.com/v2/resize:fill:32:32/1*QgtFRscRjbI92j5PPpsfEg.jpeg)](https://medium.com/@itsuki.enjoy?source=---byline--eaf59ab552c2---------------------------------------)

[Itsuki](https://medium.com/@itsuki.enjoy?source=---byline--eaf59ab552c2---------------------------------------)

Follow

2 min read

·

Apr 7, 2026

3

1

[Listen](https://medium.com/m/signin?actionUrl=https%3A%2F%2Fmedium.com%2Fplans%3Fdimension%3Dpost_audio_button%26postId%3Deaf59ab552c2&operation=register&redirect=https%3A%2F%2Fmedium.com%2F%40itsuki.enjoy%2Fswift-when-extensioncontext-open-does-not-open-my-app-solution-eaf59ab552c2&source=---header_actions--eaf59ab552c2---------------------post_audio_button------------------)

Share

## Problem Statement

What is my problem for the day? (Yes, I ran myself into some trouble again!)

I have a container app with custom URL scheme defined

Press enter or click to view image in full size

![](https://miro.medium.com/v2/resize:fit:700/1*5xkEaLg11n7tFBx8U93oVA.png)

I have `onOpenURL` on my App Content View.

```
import SwiftUI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    print("opened!")
                }
        }
    }
}
```

And everything worked perfectly fine is I typed the URL manually into Safari.

![](https://miro.medium.com/v2/resize:fit:295/1*Lg9JlqOFHHCf6Ce6EteJrw.gif)

So! I indeed have the custom URL scheme set up correctly!

Til this point, everything was perfect!

Then I have the following function in my keyboard extension, of course, called upon some button press.

```
@objc private func openApp() {
    Task {
        guard let url = URL(string: "itsuki.example://") else {
            return
        }
        let result = await extensionContext?.open(url)
        self.textDocumentProxy.insertText(result == nil ? "nil" : result! ? "Yah!" : "No!")
    }
}
```

And guess what I got!

![](https://miro.medium.com/v2/resize:fit:295/1*ieveq-GggynJv1VFD5xi1w.gif)

**_No! No! No! No!No! No!No! No!No! No!_**

## Get Itsuki’s stories in your inbox

Join Medium for free to get updates from this writer.

Subscribe

Subscribe

Remember me for faster sign in

And of course, we cannot use `UIApplication.shared`.

Press enter or click to view image in full size

![](https://miro.medium.com/v2/resize:fit:700/1*HLQ_apMjFys_WTUDujEFIw.png)

## Solution

SwiftUI is awesome, right?

We get that `openURL` environment, right?

Of course, we cannot use that `Environment` property wrapper directly like

```
@Environment(\.openURL) private var openURL
```

unless you want that **_Accessing Environment’s value outside of being installed on a View_** warning.

But it doesn’t matter!

We can just initialize the `EnvironmentValues` directly and get that `openURL` from it!

```
@objc private func openApp() {
    Task {
        guard let url = URL(string: "itsuki.example://") else {
            return
        }
        let action = EnvironmentValues()
        action.openURL(url)
    }
}
```

And here we go!

![](https://miro.medium.com/v2/resize:fit:295/1*s7jt3VewZ9PKMwLK_gkL5w.gif)

Thank you for reading!

That’s it for this little article!

Happy opening the app!

[Swift](https://medium.com/tag/swift?source=---footer_tags--eaf59ab552c2---------------------------------------)

[IOS App Development](https://medium.com/tag/ios-app-development?source=---footer_tags--eaf59ab552c2---------------------------------------)

[IOS Development](https://medium.com/tag/ios-development?source=---footer_tags--eaf59ab552c2---------------------------------------)

3

3

1

[![Itsuki](https://miro.medium.com/v2/resize:fill:48:48/1*QgtFRscRjbI92j5PPpsfEg.jpeg)](https://medium.com/@itsuki.enjoy?source=---post_author_info--eaf59ab552c2---------------------------------------)

[![Itsuki](https://miro.medium.com/v2/resize:fill:64:64/1*QgtFRscRjbI92j5PPpsfEg.jpeg)](https://medium.com/@itsuki.enjoy?source=---post_author_info--eaf59ab552c2---------------------------------------)

Follow

[**Written by Itsuki**](https://medium.com/@itsuki.enjoy?source=---post_author_info--eaf59ab552c2---------------------------------------)

[3.2K followers](https://medium.com/@itsuki.enjoy/followers?source=---post_author_info--eaf59ab552c2---------------------------------------)

· [0 following](https://medium.com/@itsuki.enjoy/following?source=---post_author_info--eaf59ab552c2---------------------------------------)

Life is for enjoying!

Follow

[Help](https://help.medium.com/hc/en-us?source=-----eaf59ab552c2---------------------------------------)

[Status](https://status.medium.com/?source=-----eaf59ab552c2---------------------------------------)

[About](https://medium.com/about?autoplay=1&source=-----eaf59ab552c2---------------------------------------)

[Careers](https://medium.com/jobs-at-medium/work-at-medium-959d1a85284e?source=-----eaf59ab552c2---------------------------------------)

[Press](mailto:pressinquiries@medium.com)

[Blog](https://blog.medium.com/?source=-----eaf59ab552c2---------------------------------------)

[Store](https://medium.com/store)

[Privacy](https://policy.medium.com/medium-privacy-policy-f03bf92035c9?source=-----eaf59ab552c2---------------------------------------)

[Rules](https://policy.medium.com/medium-rules-30e5502c4eb4?source=-----eaf59ab552c2---------------------------------------)

[Terms](https://policy.medium.com/medium-terms-of-service-9db0094a1e0f?source=-----eaf59ab552c2---------------------------------------)

[Text to speech](https://speechify.com/medium?source=-----eaf59ab552c2---------------------------------------)