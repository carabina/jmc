//
//  SampleRateFormatter.swift
//  minimalTunes
//
//  Created by John Moody on 11/7/16.
//  Copyright © 2016 John Moody. All rights reserved.
//

import Cocoa

class SampleRateFormatter: NumberFormatter {
    
    override func string(for obj: Any?) -> String? {
        return (obj as! NSNumber).description(withLocale: Locale.current) + " Hz"
    }
    
    func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AutoreleasingUnsafeMutablePointer<AnyObject?>>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<AutoreleasingUnsafeMutablePointer<NSString?>>?) -> Bool {
        return false
    }
    
}
