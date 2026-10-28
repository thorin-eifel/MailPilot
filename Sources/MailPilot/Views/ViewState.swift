import SwiftUI

/// `@State` ist im aktuellen SDK zusätzlich ein Makro, dessen Plugin nur mit Xcode ausgeliefert wird.
/// Über diesen Alias wird direkt der Property Wrapper verwendet – so baut das Projekt auch mit den Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
