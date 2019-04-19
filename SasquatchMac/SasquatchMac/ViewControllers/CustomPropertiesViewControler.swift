// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

import Cocoa
import AppCenter

class CustomPropertiesViewControler: NSViewController, NSTableViewDelegate {
  
  enum CustomPropertyType : String {
    case Clear = "Clear"
    case String = "String"
    case Number = "Number"
    case Boolean = "Boolean"
    case DateTime = "DateTime"
    
     static let allValues = [Clear, String, Number, Boolean, DateTime]
  }
  
  class CustomProperty : NSObject {
    var key: String = ""
    @objc var type: String = CustomPropertyType.Clear.rawValue
    var string: String = ""
    var number: NSNumber = 0
    var boolean: Bool = false
    var dateTime: Date = Date.init()
  }
  
  var appCenter: AppCenterDelegate = AppCenterProvider.shared().appCenter!
  
  @IBOutlet var arrayController: NSArrayController!
  @IBOutlet weak var tableView: NSTableView!
  @objc dynamic var properties = [CustomProperty]()
  
  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.delegate = self
  }
  
  @IBAction func addProperty(_ sender: Any) {
    let property = CustomProperty()
    property.addObserver(self, forKeyPath: #keyPath(CustomProperty.type), options: .new, context: nil)
    arrayController.addObject(property)
  }
  
  @IBAction func deleteProperty(_ sender: Any) {
    if let selectedProperty = arrayController.selectedObjects.first as? CustomProperty {
      arrayController.removeObject(selectedProperty)
      selectedProperty.removeObserver(self, forKeyPath: #keyPath(CustomProperty.type), context: nil)
    }
  }
  
  @IBAction func send(_ sender: Any) {
    let customProperties = MSCustomProperties()
    for property in properties {
      let key = property.key
      guard let type = CustomPropertyType(rawValue: property.type) else {
        continue
      }
      switch type {
      case .Clear:
        customProperties.clearProperty(forKey: key)
      case .String:
        customProperties.setString(property.string, forKey: key)
      case .Number:
        customProperties.setNumber(property.number, forKey: key)
      case .Boolean:
        customProperties.setBool(property.boolean, forKey: key)
      case .DateTime:
        customProperties.setDate(property.dateTime, forKey: key)
      }
    }
    appCenter.setCustomProperties(customProperties)
  }
  
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let identifier = convertFromNSUserInterfaceItemIdentifier((tableColumn?.identifier)!)
    let view = tableView.makeView(withIdentifier: convertToNSUserInterfaceItemIdentifier(identifier), owner: self)
    if (identifier == "value") {
      updateValue(property: properties[row], cell: view as! NSTableCellView)
    }
    return view
  }
  
  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let property = object as? CustomProperty else {
      return
    }
    guard let row = properties.index(of: property) else {
      return
    }
    let column = tableView.column(withIdentifier: convertToNSUserInterfaceItemIdentifier("value"))
    guard let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView else {
      return
    }
    updateValue(property: property, cell: cell)
  }
  
  func updateValue(property: CustomProperty, cell: NSTableCellView) {
    cell.isHidden = false
    for subview in cell.subviews {
      subview.isHidden = true
    }
    guard let type = CustomPropertyType(rawValue: property.type) else {
      return
    }
    if let view = cell.viewWithTag(CustomPropertyType.allValues.index(of: type)!) {
      view.isHidden = false
    } else {
      cell.isHidden = true
    }
  }
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertFromNSUserInterfaceItemIdentifier(_ input: NSUserInterfaceItemIdentifier) -> String {
	return input.rawValue
}

// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToNSUserInterfaceItemIdentifier(_ input: String) -> NSUserInterfaceItemIdentifier {
	return NSUserInterfaceItemIdentifier(rawValue: input)
}
