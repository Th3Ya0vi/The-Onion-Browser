//
//  BookmarkViewController.swift
//  OnionBrowser2
//
//  Created by Benjamin Erhart on 08.10.19.
//  Copyright (c) 2012-2019, Tigas Ventures, LLC (Mike Tigas)
//
//  This file is part of Onion Browser. See LICENSE file for redistribution terms.
//

import UIKit
import Eureka

protocol BookmarkViewControllerDelegate {

	func needsReload()
}

class BookmarkViewController: FormViewController {

	var index: Int?
	var delegate: BookmarkViewControllerDelegate?

	private var bookmark: Bookmark?

	private let titleRow = TextRow() {
		$0.placeholder = NSLocalizedString("Title", comment: "Bookmark title placeholder")
	}

	private let urlRow =  URLRow() {
		$0.placeholder = NSLocalizedString("Address", comment: "Bookmark URL placeholder")
	}

    override func viewDidLoad() {
        super.viewDidLoad()

		// Was called via "+" (add).
		if index == nil {

			// Check, if we have a valid URL in the current tab. If so, prefill with that.
			if let info = AddSiteViewController.getCurrentTabInfo() {

				// Check, if this page is already bookmarked. If so, edit that.
				if let bookmark = Bookmark.all.first(where: { $0.url == info.url }) {
					self.bookmark = bookmark
					index = Bookmark.all.firstIndex(of: bookmark)
				}
				else {
					titleRow.value = info.title
					urlRow.value = info.url
				}
			}
		}
		else {
			bookmark = Bookmark.all[index!]
		}

		navigationItem.title = index == nil
			? NSLocalizedString("Add Bookmark", comment: "Scene titlebar")
			: NSLocalizedString("Edit Bookmark", comment: "Scene title")

		if index == nil {
			navigationItem.rightBarButtonItem = UIBarButtonItem(
				barButtonSystemItem: .save, target: self, action: #selector(addNew))

			// Don't allow to store empty bookmarks.
			navigationItem.rightBarButtonItem?.isEnabled = urlRow.value != nil
		}

		if let bookmark = bookmark {
			titleRow.value = bookmark.name
			urlRow.value = bookmark.url
		}

		form
			+++ titleRow
			<<< urlRow
			.onChange { row in
				self.navigationItem.rightBarButtonItem?.isEnabled = row.value != nil
			}
    }

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)

		// Store changes, if user edits an existing bookmark or bookmark was created
		// with #addNew.
		if index != nil {
			bookmark?.name = titleRow.value

			// Don't allow empty URL.
			if let url = urlRow.value {
				bookmark?.url = url
			}

			Bookmark.store()

			delegate?.needsReload()
		}
	}

	@objc private func addNew() {
		if urlRow.value != nil {
			bookmark = Bookmark()

			Bookmark.all.append(bookmark!)
			// Trigger store in #viewWillDisappear by setting index != nil.
			index = Bookmark.all.firstIndex(of: bookmark!)

			navigationController?.popViewController(animated: true)
		}
	}
}
