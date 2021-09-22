# ``ITwinMobile``

Use this to integrate iTwinJS functionality into native iOS apps.

## Overview

This package is designed to make it easier to use iTwinJS functionality in a native iOS app. Interactions with iTwinJS happen inside a WKWebView using JavaScript. So this SDK simplifies the creation and setup of a WKWebView for use with iTwinJS, as well as loading the backend and frontend content. Additionally, it provides a number of native UI components, as well as a framework for adding your own custom ones. 

Interaction with the API starts with the ``ITMApplication`` class. You use this to create and configure the WKWebView in which the iTwinJS application will run. A convenience ``ITMViewController`` can be used to show the web view.

## Topics

### Main Classes

- ``ITMApplication``
- ``ITMMessenger``
- ``ITMViewController``

### Other Classes

- ``ITMError``
- ``ITMGeolocationManager``
- ``ITMLogger``
- ``ITMNativeUI``
- ``ITMNativeUIComponent``
- ``ITMWeakScriptMessageHandler``
- ``ITMWebViewLogger``
