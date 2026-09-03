interface Node {
  Node appendChild(Node node);
};

interface Element {
  attribute DOMString innerHTML;
  attribute DOMString textContent;
  attribute double scrollLeft;
  attribute double scrollTop;
  undefined setAttribute(DOMString name, DOMString value);
  Node appendChild(Node node);
};

interface Text {
  attribute DOMString data;
};

interface Document {
  Element createElement(DOMString localName);
  Element createElementNS(DOMString namespace, DOMString qualifiedName);
  Text createTextNode(DOMString data);
  readonly attribute Element head;
  readonly attribute Element body;
  Node appendChild(Node node);
};

// The browser's cryptographically secure random source. `getRandomValues`
// fills the array it is given, so the binding hands it a view over wasm memory
// and the bytes land in the caller's own slice.
interface Crypto {
  // The real signature returns the same array it filled. Declared `undefined`
  // here on purpose: a declared buffer return is copied out of JS into wasm
  // memory and handed over as owned, so taking it would allocate a duplicate of
  // the bytes on every call and leave the caller to free it. The array the
  // caller passed in is already filled in place.
  undefined getRandomValues(Uint8Array array);
};

interface Location {
  readonly attribute DOMString pathname;
  // The page host with no port on it. `web_net.requestUrl` compares a request
  // against this to decide whether the browser can resolve the request against
  // the page, and a request carries a bare host name with its port kept apart,
  // so `hostname` is the one that can match and `host` is not.
  readonly attribute DOMString hostname;
  // Navigates this tab. What a sign in hop needs: a person leaves for the
  // forge and comes back to the callback in the tab they started in, and a
  // popup blocker cannot refuse it the way it can refuse a new window.
  undefined assign(DOMString url);
  // The query string, the leading "?" included, and empty when there is none.
  // A redirect that comes back carrying a state or an error puts it here, and
  // it is where a deep link keeps what is not part of the route.
  readonly attribute DOMString search;
  attribute DOMString hash;
};

interface History {
  undefined pushState(DOMString data, DOMString title, DOMString url);
  undefined replaceState(DOMString data, DOMString title, DOMString url);
};

interface Window {
  readonly attribute unsigned long innerWidth;
  readonly attribute unsigned long innerHeight;
  readonly attribute double devicePixelRatio;
  readonly attribute Location location;
  readonly attribute History history;
  readonly attribute Crypto crypto;
  // Returns the new window, or null when the browser refused to open one,
  // which is what a popup blocker does. The caller has to see that: a page
  // that announces a tab which is not there is worse than one that says it
  // could not open it.
  Window open(DOMString url, DOMString target);
  // Reports a message to the console as an uncaught error. This is how a panic
  // in wasm says anything at all: the trap on its own reaches a developer as
  // "RuntimeError: unreachable" with nothing in it.
  undefined reportError(DOMString message);
};
