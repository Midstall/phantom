interface Node {
  Node appendChild(Node node);
};

interface Element {
  attribute DOMString innerHTML;
  attribute DOMString textContent;
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

interface Location {
  readonly attribute DOMString pathname;
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
  undefined open(DOMString url, DOMString target);
};
