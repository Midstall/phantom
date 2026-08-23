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

interface Window {
  readonly attribute unsigned long innerWidth;
  readonly attribute unsigned long innerHeight;
  readonly attribute double devicePixelRatio;
};
