[![](https://keyboardkit.com/assets/icon/header.png)](https://keyboardkit.com/)[KeyboardKit](https://keyboardkit.com/)

[About](https://keyboardkit.com/about) [Blog](https://keyboardkit.com/blog) [Features](https://keyboardkit.com/features) [Pro](https://keyboardkit.com/pro) [Pricing](https://keyboardkit.com/pricing)

[Blog](https://keyboardkit.com/blog)

On This Page

# iOS 18 breaks the selector-based way of opening URLs

Sep 11, 20242 min read

actionsnavigation

iOS 18 causes the selector-based way of opening URLs from a keyboard extension without the main application, to stop working. This post describes how KeyboardKit will fix it.

The `KeyboardInputViewController` has an `openURL` function that uses a selector to open URLs:

```
open func openUrl(_ url: URL?) {
    let selector = sel_registerName("openURL:")
    var responder = self as UIResponder?
    while let r = responder, !r.responds(to: selector) {
        responder = r.next
    }
    _ = responder?.perform(selector, with: url)
}
```

This works great in iOS 17, but in iOS 18 you get the following system log:

```
BUG IN CLIENT OF UIKIT: The caller of UIApplication.openURL(_:) needs to migrate to the non-deprecated UIApplication.open(_:options:completionHandler:). Force returning false (NO).
Trying to use openURL:options:completionHandler: doesn't seem to work either, which means that there is currently no way to handle the .url keyboard action.
```

Using `openURL:options:completionHandler:` doesn’t work either, which means that there is currently no way to handle the `.url` keyboard action with the controller.

To work around this problem, KeyboardKit 8.8.6 will render `.url` actions as SwiftUI `Link`s, instead of a view with the full range of button gestures.

To work around this problem with earlier versions of KeyboardKit, use regular `Link`s in your UI and customize the `SystemKeyboard`/`KeyboardView` button builder to return a `Link` for the button content.

You are most welcome to discuss this in [this GitHub issue](https://github.com/KeyboardKit/KeyboardKit/issues/795). Perhaps there is a way to make the selector-based approach work once more?

## Discussions & More

If you found this interesting, please share your thoughts on
[Bluesky](https://bsky.app/profile/keyboardkit.bsky.social) and
[Mastodon](https://techhub.social/@keyboardkit/113117869193627340).
Make sure to follow to be notified when new content is published.


Site

[Home](https://keyboardkit.com/) [About](https://keyboardkit.com/about) [App](https://keyboardkit.com/app) [FAQ](https://keyboardkit.com/faq) [Industries](https://keyboardkit.com/industries) [Case Studies](https://keyboardkit.com/case-studies)

SDK

[Features](https://keyboardkit.com/features) [KeyboardKit Pro](https://keyboardkit.com/pro) [Pricing](https://keyboardkit.com/pricing) [Business Licenses](https://keyboardkit.com/business-licenses) [Terms & Conditions](https://keyboardkit.com/pro/terms) [Privacy Policy](https://keyboardkit.com/privacy)

News & Press

[Blog](https://keyboardkit.com/blog) [RSS](https://keyboardkit.com/feed.xml) [Newsletter](https://kankoda.gumroad.com/subscribe) [Press](https://keyboardkit.com/press)

Code

[GitHub](https://github.com/KeyboardKit/KeyboardKit) [Get Started](https://keyboardkit.com/get-started) [Binaries & dSYMs](https://github.com/KeyboardKit/KeyboardKit-Binaries) [Documentation](https://keyboardkit.com/documentation) [Issue Tracker](https://github.com/KeyboardKit/KeyboardKit/issues)

Contact

[Contact](https://keyboardkit.com/contact) [Bluesky](https://bsky.app/profile/keyboardkit.bsky.social) [Mastodon](https://techhub.social/@keyboardkit) [Reddit](https://www.reddit.com/r/KeyboardKit) [Schedule a call](https://calendar.app.google/HyJeUXdRczwkp3Jh6)

© 2016-2026 [Kankoda Sweden AB](https://kankoda.com/).
All rights reserved.