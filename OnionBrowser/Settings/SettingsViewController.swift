//
//  SettingsViewController.swift
//  OnionBrowser2
//
//  Created by Benjamin Erhart on 09.10.19.
//  Copyright (c) 2012-2019, Tigas Ventures, LLC (Mike Tigas)
//
//  This file is part of Onion Browser. See LICENSE file for redistribution terms.
//

import UIKit
import Eureka
import POE

class SettingsViewController: FormViewController {

	private let defaultSecurityRow = LabelRow() {
		$0.title = NSLocalizedString("Default Security", comment: "Option title")
		$0.cell.textLabel?.numberOfLines = 0
		$0.cell.accessoryType = .disclosureIndicator
		$0.cell.selectionStyle = .default
	}


    @objc
	class func instantiate() -> UINavigationController {
		return UINavigationController(rootViewController: self.init())
	}

	override func viewDidLoad() {
        super.viewDidLoad()

		navigationItem.leftBarButtonItem = UIBarButtonItem(
			barButtonSystemItem: .done, target: self, action: #selector(dismsiss_))
		navigationItem.title = NSLocalizedString("Settings", comment: "Scene title")

		form
		+++ defaultSecurityRow
		.onCellSelection { _, _ in
			self.navigationController?.pushViewController(
				SecurityViewController(), animated: true)
		}

		+++ Section(header: NSLocalizedString("Search", comment: "Section header"),
					footer: NSLocalizedString("When disabled, all text entered in search bar will be sent to the search engine unless it starts with \"http\".",
											  comment: "Explanation in section footer"))

		<<< PushRow<String>() {
			$0.title = NSLocalizedString("Search Engine", comment: "Option title")
			$0.selectorTitle = $0.title
			$0.options = Settings.allSearchEngineNames
			$0.value = Settings.searchEngineName
			$0.cell.textLabel?.numberOfLines = 0
		}
		.onChange { row in
			if let value = row.value {
				Settings.searchEngineName = value
			}
		}

		<<< SwitchRow() {
			$0.title = NSLocalizedString("Auto-Complete Search Results", comment: "Option title")
			$0.value = Settings.searchLive
			$0.cell.switchControl.onTintColor = .poeAccent
			$0.cell.textLabel?.numberOfLines = 0
		}
		.onChange { row in
			if let value = row.value {
				Settings.searchLive = value
			}
		}

		<<< SwitchRow() {
			$0.title = NSLocalizedString("Stop Auto-Complete at First Dot", comment: "Option title")
			$0.value = Settings.searchLiveStopDot
			$0.cell.switchControl.onTintColor = .poeAccent
			$0.cell.textLabel?.numberOfLines = 0
		}
		.onChange { row in
			if let value = row.value {
				Settings.searchLiveStopDot = value
			}
		}

		+++ Section(header: NSLocalizedString("Privacy & Security", comment: "Section header"),
					footer: NSLocalizedString("Choose how long app remembers open tabs.", comment: "Explanation in section footer"))

		<<< LabelRow() {
			$0.title = NSLocalizedString("Custom Site Security", comment: "Option label")
			$0.cell.textLabel?.numberOfLines = 0
			$0.cell.accessoryType = .disclosureIndicator
			$0.cell.selectionStyle = .default
		}
		.onCellSelection { _, _ in
			self.navigationController?.pushViewController(CustomSitesViewController(), animated: true)
		}

		<<< SwitchRow() {
			$0.title = NSLocalizedString("Send Do-Not-Track Header", comment: "Option title")
			$0.value = Settings.sendDnt
			$0.cell.switchControl.onTintColor = .poeAccent
			$0.cell.textLabel?.numberOfLines = 0
		}
		.onChange { row in
			if let value = row.value {
				Settings.sendDnt = value
			}
		}

		<<< LabelRow() {
			$0.title = NSLocalizedString("Cookies and Local Storage", comment: "Option title")
			$0.cell.textLabel?.numberOfLines = 0
			$0.cell.accessoryType = .disclosureIndicator
			$0.cell.selectionStyle = .default
		}
		.onCellSelection { _, _ in
			self.navigationController?.pushViewController(
				Storage1ViewController(), animated: true)
		}

		<<< PushRow<Settings.TlsVersion>() {
			$0.title = NSLocalizedString("TLS Version", comment: "Option title")
			$0.selectorTitle = $0.title
			$0.options = [Settings.TlsVersion.tls13,
						  Settings.TlsVersion.tls12,
						  Settings.TlsVersion.tls10]

			$0.value = Settings.tlsVersion

			$0.cell.textLabel?.numberOfLines = 0
		}
		.onPresent { vc, selectorVc in
			// This is just to trigger the usage of #sectionFooterTitleForKey
			selectorVc.sectionKeyForValue = { value in
				return NSLocalizedString("TLS Version", comment: "Option title")
			}

			selectorVc.sectionFooterTitleForKey = { key in
				return NSLocalizedString("Minimum version of TLS required for hosts to negotiate HTTPS connections.",
										 comment: "Option description")
			}
		}
		.onChange { row in
			if let value = row.value {
				Settings.tlsVersion = value
			}
		}

		<<< PushRow<TabSecurity.Level>() {
			$0.title = NSLocalizedString("Tab Security", comment: "Option title")
			$0.selectorTitle = $0.title
			$0.options = [TabSecurity.Level.alwaysRemember,
						  TabSecurity.Level.forgetOnShutdown,
						  TabSecurity.Level.clearOnBackground]

			$0.value = Settings.tabSecurity

			$0.cell.textLabel?.numberOfLines = 0
		}
		.onChange { row in
			if let value = row.value {
				Settings.tabSecurity = value
			}
		}

		+++ Section(header: NSLocalizedString("Miscellaneous", comment: "Section header"),
					footer: NSLocalizedString("Changing this option requires restarting the app.",
											  comment: "Option explanation"))

		<<< SwitchRow() {
			$0.title = NSLocalizedString("Mute Audio with Mute Switch", comment: "Option title")
			$0.value = Settings.muteWithSwitch
			$0.cell.switchControl.onTintColor = .poeAccent
			$0.cell.textLabel?.numberOfLines = 0
		}
		.onChange { row in
			if let value = row.value {
				Settings.muteWithSwitch = value
			}
		}

		<<< SwitchRow() {
			$0.title = NSLocalizedString("Allow 3rd-Party Keyboards", comment: "Option title")
			$0.value = Settings.thirdPartyKeyboards
			$0.cell.switchControl.onTintColor = .poeAccent
			$0.cell.textLabel?.numberOfLines = 0
		}
		.onChange { row in
			if let value = row.value {
				Settings.thirdPartyKeyboards = value
			}
		}


		let section = Section(header: NSLocalizedString("Support", comment: "Section header"),
							  footer: String(
								format: NSLocalizedString("Version %@", comment: "Version info at end of scene"),
								Bundle.main.version))

		form
		+++ section
		<<< ButtonRow() {
			$0.title = NSLocalizedString("Report a Bug", comment: "Button title")
			$0.cell.textLabel?.numberOfLines = 0
		}
		.cellUpdate { cell, _ in
			cell.textLabel?.textAlignment = .natural
		}
		.onCellSelection { _, _ in
			AppDelegate.shared()?.webViewController.addNewTab(
				for: URL(string: "https://github.com/OnionBrowser/OnionBrowser/issues"),
				forRestoration: false, with: .quick, withCompletionBlock: nil)

			self.dismsiss_()
		}

		if let url = URL(string: "itms-apps://itunes.apple.com/app/id519296448"),
			UIApplication.shared.canOpenURL(url) {

			section
			<<< ButtonRow() {
				$0.title = NSLocalizedString("Rate on App Store", comment: "Button title")
				$0.cell.textLabel?.numberOfLines = 0
			}
			.cellUpdate { cell, _ in
				cell.textLabel?.textAlignment = .natural
			}
			.onCellSelection { _, _ in
				UIApplication.shared.open(url, options: [:])
			}
		}

		section
		<<< LabelRow() {
			$0.title = NSLocalizedString("Fund Development", comment: "Button title")
			$0.cell.textLabel?.numberOfLines = 0
			$0.cell.accessoryType = .disclosureIndicator
			$0.cell.selectionStyle = .default
		}
		.onCellSelection { _, _ in
			self.navigationController?.pushViewController(DonationViewController(), animated: true)
		}

		<<< ButtonRow() {
			$0.title = NSLocalizedString("About", comment: "Button title")
			$0.cell.textLabel?.numberOfLines = 0
		}
		.cellUpdate { cell, _ in
			cell.textLabel?.textAlignment = .natural
		}
		.onCellSelection { _, _ in
			AppDelegate.shared()?.webViewController.addNewTab(
				for: URL(string: ABOUT_ONION_BROWSER), forRestoration: false,
				with: .quick, withCompletionBlock: nil)

			self.dismsiss_()
		}
    }

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		defaultSecurityRow.value = SecurityPreset(HostSettings.default()).description
		defaultSecurityRow.updateCell()
	}

	@objc private func dismsiss_() {
		navigationController?.dismiss(animated: true)
	}
}
